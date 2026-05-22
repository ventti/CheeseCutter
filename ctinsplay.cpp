/*
 * CheeseCutter Instrument Player
 * 
 * A standalone tool to play CheeseCutter .cti instrument files
 * Uses ReSID engine for audio synthesis
 * 
 * Usage:
 *   ctinsplay <instrument.cti> [options]
 *   
 * Options:
 *   -n, --note <value>       Note value (0-95, default: 36 = C-3)
 *   -d, --duration <ms>      Duration in milliseconds (default: 2000)
 *   -r, --samplerate <hz>    Sample rate (default: 48000)
 *   -o, --output <file>      Output to ProTracker sample file
 *   -m, --model <6581|8580>  SID model (default: 6581)
 *   -c, --clock <pal|ntsc>   Clock mode (default: pal)
 *   -h, --help               Show this help
 */

#include <iostream>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include <cstring>
#include <cstdlib>
#include <getopt.h>
#include <SDL.h>

// ReSID includes
#include "resid/sid.h"

// PAL and NTSC clock rates
#define PALCLOCKRATE 985248
#define NTSCCLOCKRATE 1022727
#define PAL_FPS 50.125
#define NTSC_FPS 60.0

// Forward declarations
struct InstrumentData;
bool parseInstrumentFile(const std::string& filename, InstrumentData& instr);
void playInstrument(const InstrumentData& instr, int note, int duration_ms, 
                   int samplerate, int sidModel, bool ntsc, const std::string& outputFile);
uint16_t getNoteFrequency(int note);

// Instrument data structure matching CheeseCutter format
struct InstrumentData {
    std::string name;
    uint8_t def[8];      // Instrument definition (8 bytes)
    std::vector<uint8_t> wave1;
    std::vector<uint8_t> wave2;
    std::vector<uint8_t> pulse;
    std::vector<uint8_t> filter;
};

// SID frequency table for PAL (96 notes)
static const uint16_t freqTable[96] = {
    0x0116, 0x0127, 0x0138, 0x014B, 0x015F, 0x0173,
    0x018A, 0x01A1, 0x01BA, 0x01D4, 0x01F0, 0x020E,
    0x022D, 0x024E, 0x0271, 0x0296, 0x02BD, 0x02E7,
    0x0313, 0x0342, 0x0374, 0x03A9, 0x03E0, 0x041B,
    0x045A, 0x049B, 0x04E2, 0x052C, 0x057B, 0x05CE,
    0x0627, 0x0685, 0x06E8, 0x0751, 0x07C1, 0x0837,
    0x08B4, 0x0937, 0x09C4, 0x0A57, 0x0AF5, 0x0B9C,
    0x0C4E, 0x0D09, 0x0DD0, 0x0EA3, 0x0F82, 0x106E,
    0x1168, 0x126E, 0x1388, 0x14AF, 0x15EB, 0x1739,
    0x189C, 0x1A13, 0x1BA1, 0x1D46, 0x1F04, 0x20DC,
    0x22D0, 0x24DC, 0x2710, 0x295E, 0x2BD6, 0x2E72,
    0x3138, 0x3426, 0x3742, 0x3A8C, 0x3E08, 0x41B8,
    0x45A0, 0x49B8, 0x4E20, 0x52BC, 0x57AC, 0x5CE4,
    0x6270, 0x684C, 0x6E84, 0x7518, 0x7C10, 0x8370,
    0x8B40, 0x9370, 0x9C40, 0xA578, 0xAF58, 0xB9C8,
    0xC4E0, 0xD098, 0xDD08, 0xEA30, 0xF820, 0xFD2E
};

uint16_t getNoteFrequency(int note) {
    if (note < 0) note = 0;
    if (note >= 96) note = 95;
    return freqTable[note];
}

// Parse hex string to byte array
std::vector<uint8_t> parseHexString(const std::string& hexStr) {
    std::vector<uint8_t> result;
    for (size_t i = 0; i < hexStr.length(); i += 2) {
        if (i + 1 < hexStr.length()) {
            std::string byteStr = hexStr.substr(i, 2);
            uint8_t byte = (uint8_t)strtol(byteStr.c_str(), nullptr, 16);
            result.push_back(byte);
        }
    }
    return result;
}

// Parse CheeseCutter instrument file (.cti format)
// Format: playerid`name`def`wave1`wave2`pulse`filter
bool parseInstrumentFile(const std::string& filename, InstrumentData& instr) {
    std::ifstream file(filename);
    if (!file.is_open()) {
        std::cerr << "Error: Cannot open file " << filename << std::endl;
        return false;
    }

    std::string line;
    std::getline(file, line);
    file.close();

    // Split by backtick delimiter
    std::vector<std::string> fields;
    std::stringstream ss(line);
    std::string field;
    
    while (std::getline(ss, field, '`')) {
        fields.push_back(field);
    }

    if (fields.size() < 7) {
        std::cerr << "Error: Invalid instrument file format (expected 7 fields, got " 
                  << fields.size() << ")" << std::endl;
        return false;
    }

    // Parse fields
    // fields[0] = playerid (e.g., "cc4.07")
    instr.name = fields[1];
    
    // Parse definition bytes
    auto defBytes = parseHexString(fields[2]);
    if (defBytes.size() < 8) {
        std::cerr << "Error: Instrument definition must be 8 bytes" << std::endl;
        return false;
    }
    std::copy(defBytes.begin(), defBytes.begin() + 8, instr.def);
    
    // Parse wave tables
    instr.wave1 = parseHexString(fields[3]);
    instr.wave2 = parseHexString(fields[4]);
    
    // Parse pulse and filter tables
    instr.pulse = parseHexString(fields[5]);
    instr.filter = parseHexString(fields[6]);

    return true;
}

// Wave table interpreter
class WaveTablePlayer {
private:
    const std::vector<uint8_t>& wave1;
    const std::vector<uint8_t>& wave2;
    int position;
    int delay;
    int delayCounter;
    
public:
    WaveTablePlayer(const std::vector<uint8_t>& w1, const std::vector<uint8_t>& w2)
        : wave1(w1), wave2(w2), position(0), delay(1), delayCounter(0) {}
    
    void reset() {
        position = 0;
        delay = 1;
        delayCounter = 0;
    }
    
    bool step(uint8_t& waveform, int8_t& transpose) {
        if (wave1.empty() || position >= (int)wave1.size()) {
            return false;
        }
        
        if (delayCounter > 0) {
            delayCounter--;
            return true;
        }
        
        uint8_t byte1 = wave1[position];
        uint8_t byte2 = wave2[position];
        
        // Check for loop commands
        if (byte1 == 0x7F || byte1 == 0x7E) {
            // Loop: byte2 contains the loop target
            if (byte1 == 0x7E) {
                position = (position > 0) ? position - 1 : 0;
            } else {
                position = byte2;
            }
            if (position >= (int)wave1.size()) position = 0;
            return true;
        }
        
        // Get transpose value
        if (byte1 < 0x60) {
            transpose = byte1;
        } else if (byte1 >= 0x80 && byte1 < 0xE0) {
            // Absolute tuning (not affected by note)
            transpose = byte1 - 0x80;
        }
        
        // Get waveform from byte2
        if (byte2 >= 0x10 && byte2 < 0xE0) {
            waveform = byte2;
        } else if (byte2 >= 0xE0 && byte2 < 0xF0) {
            waveform = byte2 - 0xE0;
        } else if (byte2 >= 0x01 && byte2 <= 0x0F) {
            delay = byte2;
        }
        
        delayCounter = delay - 1;
        position++;
        
        return true;
    }
};

// Pulse table interpreter
class PulseTablePlayer {
private:
    const std::vector<uint8_t>& pulse;
    int position;
    int duration;
    int counter;
    uint16_t currentPulse;
    int8_t addValue;
    
public:
    PulseTablePlayer(const std::vector<uint8_t>& p)
        : pulse(p), position(0), duration(0), counter(0), currentPulse(0x800), addValue(0) {}
    
    void reset() {
        position = 0;
        duration = 0;
        counter = 0;
        currentPulse = 0x800;
    }
    
    bool step(uint16_t& pulseWidth) {
        if (pulse.empty() || position >= (int)pulse.size()) {
            pulseWidth = currentPulse;
            return false;
        }
        
        if (counter > 0) {
            counter--;
            // Apply pulse modulation
            if (duration & 0x80) {
                currentPulse -= addValue;
            } else {
                currentPulse += addValue;
            }
            pulseWidth = currentPulse;
            return true;
        }
        
        // Read next pulse entry (4 bytes)
        if (position + 3 >= (int)pulse.size()) {
            pulseWidth = currentPulse;
            return false;
        }
        
        uint8_t dur = pulse[position];
        addValue = pulse[position + 1];
        uint8_t initLo = pulse[position + 2];
        uint8_t ptr = pulse[position + 3];
        
        // Check for end marker
        if (ptr == 0x7F) {
            pulseWidth = currentPulse;
            return false;
        }
        
        // Initialize pulse value (note: nibbles reversed in format)
        currentPulse = (initLo & 0x0F) << 8 | (initLo & 0xF0) >> 4;
        
        duration = dur & 0x7F;
        counter = duration;
        
        // Move to next entry or loop
        if (ptr > 0 && ptr < 0x40) {
            position = ptr * 4;
        } else {
            position += 4;
        }
        
        pulseWidth = currentPulse;
        return true;
    }
};

// Play instrument using ReSID
void playInstrument(const InstrumentData& instr, int note, int duration_ms,
                   int samplerate, int sidModel, bool ntsc, const std::string& outputFile) {
    
    std::cout << "Playing instrument: " << instr.name << std::endl;
    std::cout << "Note: " << note << " Duration: " << duration_ms << "ms" << std::endl;
    std::cout << "Sample rate: " << samplerate << " Hz" << std::endl;
    std::cout << "SID model: " << (sidModel == 1 ? "8580" : "6581") << std::endl;
    std::cout << "Clock: " << (ntsc ? "NTSC" : "PAL") << std::endl;
    
    // Initialize ReSID
    SID sid;
    sid.set_chip_model(sidModel == 1 ? MOS8580 : MOS6581);
    
    int clockrate = ntsc ? NTSCCLOCKRATE : PALCLOCKRATE;
    double framerate = ntsc ? NTSC_FPS : PAL_FPS;
    
    sid.set_sampling_parameters(clockrate, SAMPLE_INTERPOLATE, samplerate, 20000);
    sid.reset();
    
    // Calculate sample count
    int totalSamples = (samplerate * duration_ms) / 1000;
    std::vector<short> buffer(totalSamples);
    
    // Get note frequency
    uint16_t freq = getNoteFrequency(note);
    
    // Set up initial SID registers
    uint8_t attack = (instr.def[0] >> 4) & 0x0F;
    uint8_t decay = instr.def[0] & 0x0F;
    uint8_t sustain = (instr.def[1] >> 4) & 0x0F;
    uint8_t release = instr.def[1] & 0x0F;
    
    // Write frequency (voice 0)
    sid.write(0x00, freq & 0xFF);          // Freq Lo
    sid.write(0x01, (freq >> 8) & 0xFF);   // Freq Hi
    
    // Write pulse width (default 0x800)
    sid.write(0x02, 0x00);                 // PW Lo
    sid.write(0x03, 0x08);                 // PW Hi
    
    // Write ADSR
    sid.write(0x05, (attack << 4) | decay);      // Attack/Decay
    sid.write(0x06, (sustain << 4) | release);   // Sustain/Release
    
    // Write volume
    sid.write(0x18, 0x0F);                 // Volume = 15
    
    // Initialize wave table player
    WaveTablePlayer wavePlayer(instr.wave1, instr.wave2);
    PulseTablePlayer pulsePlayer(instr.pulse);
    
    // Calculate cycles per frame
    cycle_count cyclesPerFrame = clockrate / framerate;
    cycle_count cyclesPerSample = clockrate / samplerate;
    
    // Rendering loop
    int samplePos = 0;
    cycle_count cycleCounter = 0;
    
    uint8_t waveform = 0x11;  // Default: triangle + gate
    int8_t transpose = 0;
    uint16_t pulseWidth = 0x800;
    
    // Initial gate on
    sid.write(0x04, waveform | 0x01);
    
    while (samplePos < totalSamples) {
        // Update wavetable every frame
        if (cycleCounter >= cyclesPerFrame) {
            cycleCounter -= cyclesPerFrame;
            
            // Step wave table
            if (wavePlayer.step(waveform, transpose)) {
                sid.write(0x04, waveform);
            }
            
            // Step pulse table
            if (pulsePlayer.step(pulseWidth)) {
                sid.write(0x02, pulseWidth & 0xFF);
                sid.write(0x03, (pulseWidth >> 8) & 0x0F);
            }
        }
        
        // Render one sample
        cycle_count delta = cyclesPerSample;
        int n = sid.clock(delta, &buffer[samplePos], 1);
        samplePos += n;
        cycleCounter += cyclesPerSample;
    }
    
    // Output audio
    if (!outputFile.empty()) {
        // Write ProTracker sample format (IFF 8SVX)
        std::cout << "Writing ProTracker sample to: " << outputFile << std::endl;
        
        std::ofstream out(outputFile, std::ios::binary);
        if (!out.is_open()) {
            std::cerr << "Error: Cannot write output file" << std::endl;
            return;
        }
        
        // Convert 16-bit signed to 8-bit signed
        std::vector<int8_t> sample8bit(totalSamples);
        for (int i = 0; i < totalSamples; i++) {
            sample8bit[i] = buffer[i] >> 8;
        }
        
        // Write IFF 8SVX header
        out.write("FORM", 4);
        uint32_t fileSize = totalSamples + 36;
        uint32_t fileSizeBE = __builtin_bswap32(fileSize);
        out.write((char*)&fileSizeBE, 4);
        out.write("8SVX", 4);
        
        // VHDR chunk
        out.write("VHDR", 4);
        uint32_t vhdrSize = __builtin_bswap32(20);
        out.write((char*)&vhdrSize, 4);
        uint32_t oneShotHiSamples = __builtin_bswap32(totalSamples);
        out.write((char*)&oneShotHiSamples, 4);
        uint32_t repeatHiSamples = __builtin_bswap32(0);
        out.write((char*)&repeatHiSamples, 4);
        uint32_t samplesPerHiCycle = __builtin_bswap32(0);
        out.write((char*)&samplesPerHiCycle, 4);
        uint16_t samplesPerSecBE = __builtin_bswap16(samplerate);
        out.write((char*)&samplesPerSecBE, 2);
        uint8_t ctOctave = 1;
        out.write((char*)&ctOctave, 1);
        uint8_t sCompression = 0;
        out.write((char*)&sCompression, 1);
        uint32_t volume = __builtin_bswap32(0x10000);
        out.write((char*)&volume, 4);
        
        // BODY chunk
        out.write("BODY", 4);
        uint32_t bodySize = __builtin_bswap32(totalSamples);
        out.write((char*)&bodySize, 4);
        out.write((char*)sample8bit.data(), totalSamples);
        
        out.close();
        std::cout << "Sample written successfully!" << std::endl;
    } else {
        // Play through SDL audio
        std::cout << "Playing audio through SDL..." << std::endl;
        
        SDL_Init(SDL_INIT_AUDIO);
        
        SDL_AudioSpec spec;
        spec.freq = samplerate;
        spec.format = AUDIO_S16SYS;
        spec.channels = 1;
        spec.samples = 2048;
        spec.callback = nullptr;
        spec.userdata = nullptr;
        
        SDL_AudioDeviceID device = SDL_OpenAudioDevice(nullptr, 0, &spec, nullptr, 0);
        if (device == 0) {
            std::cerr << "Failed to open audio device: " << SDL_GetError() << std::endl;
            SDL_Quit();
            return;
        }
        
        SDL_QueueAudio(device, buffer.data(), totalSamples * sizeof(short));
        SDL_PauseAudioDevice(device, 0);
        
        // Wait for playback
        SDL_Delay(duration_ms + 100);
        
        SDL_CloseAudioDevice(device);
        SDL_Quit();
        
        std::cout << "Playback finished." << std::endl;
    }
}

void printHelp(const char* progName) {
    std::cout << "CheeseCutter Instrument Player\n\n";
    std::cout << "Usage: " << progName << " <instrument.cti> [options]\n\n";
    std::cout << "Options:\n";
    std::cout << "  -n, --note <value>       Note value (0-95, default: 36 = C-3)\n";
    std::cout << "  -d, --duration <ms>      Duration in milliseconds (default: 2000)\n";
    std::cout << "  -r, --samplerate <hz>    Sample rate (default: 48000)\n";
    std::cout << "  -o, --output <file>      Output to ProTracker sample file (.8svx)\n";
    std::cout << "  -m, --model <6581|8580>  SID model (default: 6581)\n";
    std::cout << "  -c, --clock <pal|ntsc>   Clock mode (default: pal)\n";
    std::cout << "  -h, --help               Show this help\n\n";
    std::cout << "Examples:\n";
    std::cout << "  " << progName << " bass.cti -n 24 -d 3000\n";
    std::cout << "  " << progName << " lead.cti -n 48 -o lead_sample.8svx\n";
}

int main(int argc, char* argv[]) {
    if (argc < 2) {
        printHelp(argv[0]);
        return 1;
    }
    
    std::string filename = argv[1];
    int note = 36;  // C-3
    int duration = 2000;  // 2 seconds
    int samplerate = 48000;
    int sidModel = 0;  // 6581
    bool ntsc = false;
    std::string outputFile;
    
    // Parse command line options
    static struct option long_options[] = {
        {"note",       required_argument, 0, 'n'},
        {"duration",   required_argument, 0, 'd'},
        {"samplerate", required_argument, 0, 'r'},
        {"output",     required_argument, 0, 'o'},
        {"model",      required_argument, 0, 'm'},
        {"clock",      required_argument, 0, 'c'},
        {"help",       no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };
    
    int opt;
    int option_index = 0;
    
    while ((opt = getopt_long(argc, argv, "n:d:r:o:m:c:h", long_options, &option_index)) != -1) {
        switch (opt) {
            case 'n':
                note = atoi(optarg);
                if (note < 0 || note > 95) {
                    std::cerr << "Error: Note must be between 0 and 95" << std::endl;
                    return 1;
                }
                break;
            case 'd':
                duration = atoi(optarg);
                if (duration <= 0) {
                    std::cerr << "Error: Duration must be positive" << std::endl;
                    return 1;
                }
                break;
            case 'r':
                samplerate = atoi(optarg);
                if (samplerate < 8000 || samplerate > 96000) {
                    std::cerr << "Error: Sample rate must be between 8000 and 96000" << std::endl;
                    return 1;
                }
                break;
            case 'o':
                outputFile = optarg;
                break;
            case 'm':
                if (strcmp(optarg, "8580") == 0) {
                    sidModel = 1;
                } else if (strcmp(optarg, "6581") == 0) {
                    sidModel = 0;
                } else {
                    std::cerr << "Error: SID model must be 6581 or 8580" << std::endl;
                    return 1;
                }
                break;
            case 'c':
                if (strcmp(optarg, "ntsc") == 0) {
                    ntsc = true;
                } else if (strcmp(optarg, "pal") == 0) {
                    ntsc = false;
                } else {
                    std::cerr << "Error: Clock must be pal or ntsc" << std::endl;
                    return 1;
                }
                break;
            case 'h':
                printHelp(argv[0]);
                return 0;
            default:
                printHelp(argv[0]);
                return 1;
        }
    }
    
    // Parse instrument file
    InstrumentData instr;
    if (!parseInstrumentFile(filename, instr)) {
        return 1;
    }
    
    // Play instrument
    playInstrument(instr, note, duration, samplerate, sidModel, ntsc, outputFile);
    
    return 0;
}

