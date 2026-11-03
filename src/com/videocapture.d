/* UI preview recording: rendered SDL frames + the samples sent to SDL audio. */
module com.videocapture;

import derelict.sdl2.sdl;
import std.stdio;
import std.process;
import std.file;
import std.path;
import std.conv : to;
import std.datetime.systime : Clock;
import std.format : format;
import std.uuid : randomUUID;
import core.stdc.string : memcpy;
version(Posix) {
    import core.sys.posix.signal : signal, SIGPIPE, SIG_IGN;
    private typeof(signal(SIGPIPE, SIG_IGN)) previousSigpipe;
}

private enum FPS = 30;
private ProcessPipes encoder;
private File pcm;
private string scratch, destination;
private int width, height, sampleRate;
private uint started;
private ulong frames;
private ubyte[] pixels, pending;
// The callback only copies into preallocated memory, never allocates or writes files.
private __gshared ubyte[] audioQueue;
private __gshared size_t queued;
private __gshared bool armed, overflow;
private bool running, encoderStarted;

bool active() { return running; }

void start(int rate) {
    if(running) return;
    try {
        if(execute(["ffmpeg", "-version"]).status != 0)
            throw new Exception("FFmpeg is unavailable. Install FFmpeg to record video previews.");
    } catch(Exception e) {
        throw new Exception("FFmpeg is unavailable. Install FFmpeg to record video previews.");
    }
    if(rate <= 0) throw new Exception("Audio output is unavailable. Enable audio before recording a preview.");
    sampleRate = rate;
    auto now = Clock.currTime();
    destination = format("preview_%04d%02d%02d_%02d%02d%02d_%03d.mp4",
        now.year, now.month, now.day, now.hour, now.minute, now.second,
        now.fracSecs.total!"msecs");
    scratch = buildPath(tempDir(), "cheesecutter-preview-" ~ randomUUID().toString());
    mkdir(scratch);
    try {
        pcm = File(buildPath(scratch, "audio.pcm"), "wb");
        audioQueue = new ubyte[rate * 2 * 10];
        pending = new ubyte[audioQueue.length];
        encoderStarted = false;
        width = height = 0;
        frames = 0;
        started = SDL_GetTicks();
        SDL_LockAudio();
        queued = 0;
        overflow = false;
        armed = true;
        SDL_UnlockAudio();
        version(Posix) previousSigpipe = signal(SIGPIPE, SIG_IGN);
        running = true;
    } catch(Exception e) {
        pcm.close();
        rmdirRecurse(scratch);
        throw e;
    }
}

// Called for every output buffer, including silence while playback is stopped.
void audioOutput(const(ubyte)* stream, int len) nothrow {
    if(!armed) return;
    if(queued + len > audioQueue.length) { overflow = true; return; }
    memcpy(audioQueue.ptr + queued, stream, len);
    queued += len;
}

private void drainAudio() {
    SDL_LockAudio();
    auto n = queued;
    auto failed = overflow;
    if(n) memcpy(pending.ptr, audioQueue.ptr, n);
    queued = 0;
    SDL_UnlockAudio();
    if(failed) throw new Exception("Video capture could not keep up with audio.");
    if(n) pcm.rawWrite(pending[0 .. n]);
}

// Read only before SDL_RenderPresent; duplicate frames when the UI stays still.
void frame(SDL_Renderer* renderer) {
    if(!running) return;
    drainAudio();
    auto due = cast(ulong)(SDL_GetTicks() - started) * FPS / 1000 + 1;
    if(frames >= due) return;
    int w, h;
    if(SDL_GetRendererOutputSize(renderer, &w, &h) != 0)
        throw new Exception("Could not read video capture dimensions.");
    if(width == 0) {
        width = w; height = h;
        pixels.length = width * height * 3;
        encoder = pipeProcess(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-f", "rawvideo", "-pixel_format", "rgb24", "-video_size",
            to!string(width) ~ "x" ~ to!string(height), "-framerate", to!string(FPS),
            "-i", "pipe:0", "-an", "-c:v", "libx264", "-preset", "ultrafast",
            "-crf", "18", "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2", "-pix_fmt", "yuv420p",
            buildPath(scratch, "video.mp4")], Redirect.stdin);
        encoderStarted = true;
    }
    if(w != width || h != height)
        throw new Exception("Window size changed. Recording stopped; keep the window size fixed while capturing.");
    if(SDL_RenderReadPixels(renderer, null, SDL_PIXELFORMAT_RGB24, pixels.ptr, width * 3) != 0)
        throw new Exception("Could not read video capture pixels.");
    while(frames < due) { encoder.stdin.rawWrite(pixels); frames++; }
}

private int finishEncoder() {
    if(!encoderStarted) return 0;
    // A dead encoder can make closing its pipe fail. Always reap the child.
    bool closeFailed;
    try { encoder.stdin.close(); } catch(Exception e) { closeFailed = true; }
    auto status = wait(encoder.pid);
    encoderStarted = false;
    return closeFailed ? -1 : status;
}

string stop() {
    if(!running) return "";
    SDL_LockAudio();
    armed = false;
    SDL_UnlockAudio();
    running = false;
    scope(exit) {
        audioQueue = null; pending = null; pixels = null;
        version(Posix) signal(SIGPIPE, previousSigpipe);
    }
    try {
        drainAudio();
        pcm.close();
        if(width == 0) throw new Exception("No video frames were recorded.");
        auto status = finishEncoder();
        if(status != 0) throw new Exception("FFmpeg video encoding failed.");
        auto result = execute(["ffmpeg", "-hide_banner", "-loglevel", "error", "-n",
            "-i", buildPath(scratch, "video.mp4"), "-f", "s16le", "-ar",
            to!string(sampleRate), "-ac", "1", "-i", buildPath(scratch, "audio.pcm"),
            "-c:v", "copy", "-c:a", "aac", "-af", "apad", "-t",
            to!string(cast(double)frames / FPS), "-movflags", "+faststart", destination]);
        if(result.status != 0) throw new Exception("FFmpeg could not save the preview: " ~ result.output);
        rmdirRecurse(scratch);
        return destination;
    } catch(Exception e) {
        pcm.close();
        finishEncoder();
        throw new Exception(e.msg ~ " Capture files: " ~ scratch);
    }
}
