/*
CheeseCutter v2 (C) Abaddon. Licensed under GNU GPL.

Keyboard scancode translation, including the super/cmd layer, into editor key events.
*/

module com.kbd;
import derelict.sdl2.sdl;
import ui.input : Keyinfo;

void translate(ref Keyinfo key) {
	switch(key.key) {
	case SDLK_KP_ENTER: // for shitty laptops and apple computers...
		key.key = SDLK_INSERT;
		break;
	default: break;
	}
	// do this last since platform specific translations need to be done 1st
	translate_super(key);
}

void translate_super(ref Keyinfo key) {
	version(OSX) {
		// Preserve only the explicit Mac registry chords before legacy keypad /
		// Ctrl+Shift emulation. Other Command combinations keep their behavior.
		int mods = key.mods & (KMOD_CTRL | KMOD_SHIFT | KMOD_ALT | KMOD_GUI);
		bool cmdOnly = (mods & KMOD_GUI) != 0
			&& !(mods & (KMOD_CTRL | KMOD_SHIFT | KMOD_ALT));
		bool ctrlCmdOnly = (mods & KMOD_GUI) != 0 && (mods & KMOD_CTRL) != 0
			&& !(mods & (KMOD_SHIFT | KMOD_ALT));
		if((cmdOnly && key.key >= SDLK_1 && key.key <= SDLK_3)
			|| (ctrlCmdOnly && key.key == SDLK_f)
			|| ((mods & KMOD_GUI) && (key.key == SDLK_UP || key.key == SDLK_DOWN))) return;
	}

	if(key.mods & KMOD_GUI) {
		key.fromGui = true;
        switch(key.key) {
        case SDLK_0: key.key = SDLK_KP_0; break;
        case SDLK_1: key.key = SDLK_KP_1; break;
        case SDLK_2: key.key = SDLK_KP_2; break;
        case SDLK_3: key.key = SDLK_KP_3; break;
        case SDLK_4: key.key = SDLK_KP_4; break;
        case SDLK_5: key.key = SDLK_KP_5; break;
        case SDLK_6: key.key = SDLK_KP_6; break;
        case SDLK_7: key.key = SDLK_KP_7; break;
        case SDLK_8: key.key = SDLK_KP_8; break;
        case SDLK_9: key.key = SDLK_KP_9; break;
		case SDLK_UP: key.mods = KMOD_SHIFT; key.key = SDLK_HOME; break;
		case SDLK_DOWN: key.mods = KMOD_SHIFT; key.key = SDLK_END; break;
        default: // otherwise just translate to ctrl+shift...                                                                       
            key.mods |= KMOD_CTRL | KMOD_SHIFT;
            break;
        }
		key.mods ^= KMOD_GUI; // meta off
    }
}
