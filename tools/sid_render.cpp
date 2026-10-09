// CheeseCutter prototype: deterministic PSID -> mono PCM via libsidplayfp.
// GPL-2.0-or-later, matching CheeseCutter and libsidplayfp.
#include <sidplayfp/sidplayfp.h>
#include <sidplayfp/SidTune.h>
#include <sidplayfp/SidTuneInfo.h>
#include <sidplayfp/SidInfo.h>
#include <sidplayfp/builders/sidlite.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <vector>

static void u16(std::ostream& s, uint16_t x) {
    s.put(char(x)); s.put(char(x >> 8));
}
static void u32(std::ostream& s, uint32_t x) {
    u16(s, uint16_t(x)); u16(s, uint16_t(x >> 16));
}

int main(int argc, char** argv) {
    try {
        if (argc != 7 && argc != 8) throw std::runtime_error(
            "Usage: sid_render input.sid output.wav seconds subtune samplerate model(6581|8580) [voices(all|none|1|2|3|12|13|23|123)]");
        const double seconds = std::stod(argv[3]);
        const int subtune = std::stoi(argv[4]), rate = std::stoi(argv[5]);
        const std::string model = argv[6];
        const std::string voices = argc == 8 ? argv[7] : "all";
        if (voices != "all" && voices != "none" && voices != "1" &&
            voices != "2" && voices != "3" && voices != "12" &&
            voices != "13" && voices != "23" && voices != "123")
            throw std::runtime_error("Invalid voice selection");
        if (!std::isfinite(seconds) || seconds <= 0 || seconds > 600 ||
            subtune < 1 || subtune > 32 || rate < 8000 || rate > 96000 ||
            (model != "6581" && model != "8580"))
            throw std::runtime_error("Invalid rendering parameters");
        SIDLiteBuilder builder("CheeseCutter validation");
        sidplayfp engine;
        SidTune tune(argv[1]);
        if (!tune.getStatus()) throw std::runtime_error(tune.statusString());
        if (subtune > int(tune.getInfo()->songs())) throw std::runtime_error("Subtune outside tune");
        tune.selectSong(subtune);
        if (tune.getInfo()->sidChips() != 1) throw std::runtime_error("Only single-SID rendering supported");
        SidConfig config;
        config.frequency = rate;
        config.defaultC64Model = SidConfig::PAL;
        config.forceC64Model = true;
        config.defaultSidModel = model == "8580" ? SidConfig::MOS8580 : SidConfig::MOS6581;
        config.forceSidModel = true;
        config.samplingMethod = SidConfig::RESAMPLE_INTERPOLATE;
        // The default random power-on delay prevents reproducible comparisons.
        config.powerOnDelay = 0;
        config.sidEmulation = &builder;
        if (!engine.config(config) || !engine.load(&tune)) throw std::runtime_error(engine.error());
        if (voices != "all") {
            for (unsigned voice = 0; voice < 3; ++voice)
                // SIDLite uses true = muted, despite the public header's
                // reversed parameter description. Covered by isolation tests.
                engine.mute(0, voice, voices.find(char('1' + voice)) == std::string::npos);
            engine.mute(0, 3, true); // Exclude sample playback when supported.
        }
        engine.initMixer(false);
        const uint32_t target = uint32_t(std::llround(seconds * rate));
        std::vector<short> pcm;
        pcm.reserve(target);
        // libsidplayfp 3.x runs by CPU cycles, then mixes generated samples.
        constexpr unsigned cycles = 5000;
        std::vector<short> buffer(engine.getBufSize(cycles));
        while (pcm.size() < target) {
            const int count = engine.play(cycles);
            if (count <= 0) throw std::runtime_error(engine.error());
            const unsigned mixed = engine.mix(buffer.data(), unsigned(count));
            const size_t take = std::min(size_t(mixed), size_t(target) - pcm.size());
            pcm.insert(pcm.end(), buffer.begin(), buffer.begin() + take);
        }
        std::ofstream out(argv[2], std::ios::binary);
        if (!out) throw std::runtime_error("Cannot open WAV output");
        const uint32_t bytes = target * 2;
        out.write("RIFF", 4); u32(out, 36 + bytes); out.write("WAVEfmt ", 8);
        u32(out, 16); u16(out, 1); u16(out, 1); u32(out, rate); u32(out, rate * 2);
        u16(out, 2); u16(out, 16); out.write("data", 4); u32(out, bytes);
        for (short sample : pcm) u16(out, uint16_t(sample));
        if (!out) throw std::runtime_error("Failed writing WAV");
        std::cout << "libsidplayfp " << engine.info().version()
                  << "; SIDLite; PAL; " << model << "; " << rate
                  << " Hz; mono PCM16; deterministic power-on delay 0";
        if (voices != "all") std::cout << "; voices " << voices << "; samples muted when supported";
        std::cout << "; play speed "
                  << (tune.getInfo()->songSpeed() == SidTuneInfo::SPEED_CIA_1A ? "CIA" : "VBI")
                  << "; CIA1 timerA " << engine.getCia1TimerA();
        std::cout << '\n';
        return 0;
    } catch (const std::exception& e) {
        std::cerr << "sid_render: " << e.what() << '\n';
        return 1;
    }
}
