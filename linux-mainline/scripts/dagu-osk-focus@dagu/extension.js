import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

// Chrome never sends show_input_panel. GNOME/IM focus still auto-opens the
// OSK (NTP search, omnibox). Gate keyboard.open so only an explicit tap that
// moves the text caret (or the address-bar strip) can show it. Close when
// the user taps the page or the field loses focus.
export default class DaguOskFocus extends Extension {
    enable() {
        this._im = Main.inputMethod;
        this._openTimeout = 0;
        this._closeTimeout = 0;
        this._awaitTap = false;
        this._permitOpen = false;
        this._visible = false;
        this._conns = [];
        this._winTitleId = 0;
        this._trackedWin = null;
        this._gateKeyboard();
        this._connect(this._im, 'notify::current-focus', () => {
            if (!this._im.currentFocus)
                this._close();
        });
        this._connect(this._im, 'cursor-location-changed', () => {
            if (this._awaitTap)
                this._openSoon(40);
        });
        this._connect(Main.layoutManager, 'monitors-changed', () => {
            this._patchRelayout();
        });
        this._connect(global.display, 'notify::focus-window', () => {
            this._trackFocusWindow();
            if (!this._isChrome())
                this._close();
        });
        this._connect(global.stage, 'captured-event', (_a, event) => {
            this._onPointer(event);
            return Clutter.EVENT_PROPAGATE;
        });
        this._patchRelayout();
        this._trackFocusWindow();
    }

    _connect(obj, sig, cb) {
        this._conns.push([obj, obj.connect(sig, cb)]);
    }

    _gateKeyboard() {
        const kbd = Main.keyboard;
        if (!kbd || kbd._daguOpenGate)
            return;
        kbd._daguOpenGate = true;
        this._origKbdOpen = kbd.open.bind(kbd);
        kbd.open = monitor => {
            if (!this._permitOpen)
                return;
            this._origKbdOpen(monitor);
        };
        if (typeof kbd.close === 'function')
            this._origKbdClose = kbd.close.bind(kbd);
    }

    _ungateKeyboard() {
        const kbd = Main.keyboard;
        if (!kbd || !kbd._daguOpenGate)
            return;
        if (this._origKbdOpen)
            kbd.open = this._origKbdOpen;
        kbd._daguOpenGate = false;
        this._origKbdOpen = null;
        this._origKbdClose = null;
    }

    _patchRelayout() {
        const actor = Main.keyboard?.keyboardActor;
        if (!actor || actor._daguRelayout)
            return;
        actor._daguRelayout = true;
        const orig = actor._relayout.bind(actor);
        actor._relayout = () => {
            orig();
            const mon = Main.layoutManager.keyboardMonitor;
            if (!mon)
                return;
            actor.width = mon.width;
            if (mon.width > mon.height)
                actor.height = Math.round(Math.min(mon.height * 0.46, 380));
        };
        if (typeof actor.open === 'function') {
            actor._daguActorOpen = actor.open.bind(actor);
            actor.open = immediate => {
                if (!this._permitOpen)
                    return;
                actor._daguActorOpen(immediate);
            };
        }
    }

    _isChrome() {
        const win = global.display.focus_window;
        if (!win)
            return false;
        const wm = `${win.get_wm_class() || ''} ${win.get_title() || ''}`;
        return /chrome|chromium|google-chrome/i.test(wm);
    }

    _trackFocusWindow() {
        if (this._trackedWin && this._winTitleId) {
            try {
                this._trackedWin.disconnect(this._winTitleId);
            } catch (e) {
            }
        }
        this._winTitleId = 0;
        this._trackedWin = global.display.focus_window;
        if (!this._trackedWin)
            return;
        this._winTitleId = this._trackedWin.connect('notify::title', () => {
            // Navigation / new tab: hide unless a tap just requested the OSK.
            if (!this._awaitTap)
                this._close();
        });
    }

    _eventXY(event) {
        try {
            const c = event.get_coords();
            if (Array.isArray(c))
                return [c[0], c[1]];
            if (c && 'x' in c)
                return [c.x, c.y];
        } catch (e) {
        }
        return [0, 0];
    }

    _inOmniboxBand(event) {
        if (!this._isChrome())
            return false;
        const win = global.display.focus_window;
        const [x, y] = this._eventXY(event);
        const rect = win.get_frame_rect();
        const tabs = Math.max(36, Math.round(rect.height * 0.06));
        const bar = tabs + Math.max(48, Math.round(rect.height * 0.08));
        if (x < rect.x || x > rect.x + rect.width)
            return false;
        // Skip the tab strip; only the address-bar row counts as an input tap.
        return y >= rect.y + tabs && y <= rect.y + bar;
    }

    _onPointer(event) {
        const type = event.type();
        if (type !== Clutter.EventType.TOUCH_BEGIN &&
            type !== Clutter.EventType.BUTTON_PRESS)
            return;
        if (this._inOmniboxBand(event)) {
            this._awaitTap = true;
            this._openSoon(60);
            return;
        }
        // Any other tap: wait briefly for a caret move (real text field).
        // If none, this was a page/button tap — hide the OSK.
        this._awaitTap = true;
        if (this._closeTimeout)
            GLib.source_remove(this._closeTimeout);
        this._closeTimeout = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 220, () => {
            this._closeTimeout = 0;
            this._awaitTap = false;
            this._close();
            return GLib.SOURCE_REMOVE;
        });
    }

    _openSoon(ms) {
        if (this._closeTimeout) {
            GLib.source_remove(this._closeTimeout);
            this._closeTimeout = 0;
        }
        if (this._openTimeout)
            GLib.source_remove(this._openTimeout);
        this._openTimeout = GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, () => {
            this._openTimeout = 0;
            this._awaitTap = false;
            this._open();
            return GLib.SOURCE_REMOVE;
        });
    }

    _open() {
        this._patchRelayout();
        this._permitOpen = true;
        try {
            const idx = Main.layoutManager.focusIndex;
            Main.layoutManager.keyboardIndex = idx;
            Main.keyboard?.open(idx);
            const actor = Main.keyboard?.keyboardActor;
            actor?._relayout?.();
            if (actor?._daguActorOpen)
                actor._daguActorOpen(true);
            else
                actor?.open?.(true);
        } finally {
            this._permitOpen = false;
        }
        this._visible = true;
    }

    _close() {
        if (this._openTimeout) {
            GLib.source_remove(this._openTimeout);
            this._openTimeout = 0;
        }
        this._awaitTap = false;
        this._visible = false;
        const actor = Main.keyboard?.keyboardActor;
        try {
            actor?.close?.();
        } catch (e) {
        }
        try {
            if (this._origKbdClose)
                this._origKbdClose();
            else
                Main.keyboard?.close?.();
        } catch (e) {
        }
    }

    disable() {
        if (this._openTimeout) {
            GLib.source_remove(this._openTimeout);
            this._openTimeout = 0;
        }
        if (this._closeTimeout) {
            GLib.source_remove(this._closeTimeout);
            this._closeTimeout = 0;
        }
        if (this._trackedWin && this._winTitleId) {
            try {
                this._trackedWin.disconnect(this._winTitleId);
            } catch (e) {
            }
        }
        this._winTitleId = 0;
        this._trackedWin = null;
        const actor = Main.keyboard?.keyboardActor;
        if (actor?._daguActorOpen) {
            actor.open = actor._daguActorOpen;
            delete actor._daguActorOpen;
        }
        this._ungateKeyboard();
        for (const [obj, id] of this._conns)
            obj.disconnect(id);
        this._conns = [];
    }
}
