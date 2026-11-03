module video_capture_driver;
import com.videocapture;
import derelict.sdl2.sdl;
import std.stdio;
import std.math : sin;

void main(string[] args) {
    if(args.length > 1 && args[1] == "missing") {
        try { start(48000); assert(false, "Missing ffmpeg must reject capture"); }
        catch(Exception e) {
            assert(!active());
            assert(e.msg == "FFmpeg is unavailable. Install FFmpeg to record video previews.");
            writeln(e.msg);
        }
        return;
    }
    assert(SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO) == 0);
    scope(exit) SDL_Quit();
    auto window = SDL_CreateWindow("Capture test", 0, 0, 161, 91, SDL_WINDOW_HIDDEN);
    assert(window !is null);
    scope(exit) SDL_DestroyWindow(window);
    auto renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_SOFTWARE);
    assert(renderer !is null);
    scope(exit) SDL_DestroyRenderer(renderer);
    if(args.length > 1 && args[1] == "encoder-failure") {
        start(48000);
        SDL_RenderClear(renderer);
        try { frame(renderer); SDL_Delay(100); frame(renderer); }
        catch(Exception e) {}
        bool failed;
        try { stop(); } catch(Exception e) { failed = true; }
        assert(failed && !active());
        return;
    }
    foreach(take; 0 .. 2) {
        start(48000);
        assert(active());
        short[1600] samples;
        foreach(i; 0 .. 30) {
            foreach(j; 0 .. samples.length)
                samples[j] = i < 5 || i >= 25 ? 0
                    : cast(short)(12000 * sin((i * 1600 + j) * 440.0 * 2 * 3.141592653589793 / 48000));
            audioOutput(cast(ubyte*)samples.ptr, cast(int)(samples.length * 2));
            SDL_SetRenderDrawColor(renderer, cast(ubyte)(i * 8), 30, 80, 255);
            SDL_RenderClear(renderer);
            frame(renderer);
            SDL_RenderPresent(renderer);
            SDL_Delay(34);
        }
        writeln(stop());
        assert(!active());
    }
}
