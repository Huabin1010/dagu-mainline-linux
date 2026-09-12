import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const VERSION = 'osk-gate-7';

// Chrome/GNOME open the OSK via KeyboardActor.open() and the delayed
// Actor._open() rest timer. Those bypass KeyboardManager.open. Gate both,
// and only allow a show after a page-content tap plus a caret move.
export default class DaguOskFocus extends Extension {
    enable() {
        this._im = Main.inputMethod;
        this._openTimeout = 0;
        this._closeTimeout = 0;
        this._expireTimeout = 0;
        this._userRequested = false;
        this._awaitContent = false;
        this._conns = [];
        this._visId = 0;
        this._winTitleId = 0;
        this._trackedWin = null;
        this._log(`${VERSION} enable`);
        this._gateAllOpens();
        this._connect(this._im, 'notify::current-focus', () => {
            this._log(`focus=${!!this._im.currentFocus}`);
            if (!this._im.currentFocus)
                this._close('im-blur');
        });
        this._connect(this._im, 'cursor-location-changed', () => {
            this._log(`caret await=${this._awaitContent}`);
            if (this._awaitContent)
                this._requestOpen('caret');
        });
        this._connect(Main.layoutManager, 'monitors-changed', () => {
            this._gateAllOpens();
        });
        this._connect(global.display, 'notify::focus-window', () => {
            this._trackFocusWindow();
            const chrome = this._isChrome();
            this._log(`focus chrome=${chrome} ${this._winLabel()}`);
            if (!chrome)
                this._close('not-chrome');
        });
        this._connect(global.stage, 'captured-event', (_a, event) => {
            this._onPointer(event);
            return Clutter.EVENT_PROPAGATE;
        });
        this._trackFocusWindow();
        this._connectVis();
        this._writeStatus();
    }

    _log(msg) {
        const line = `${Math.round(GLib.get_monotonic_time() / 1000)} ${msg}\n`;
        try {
            const f = Gio.File.new_for_path('/tmp/dagu-osk.log');
            const out = f.append_to(Gio.FileCreateFlags.NONE, null);
            out.write(line, null);
            out.close(null);
        } catch (e) {
        }
    }

    _writeStatus() {
        const actor = Main.keyboard?.keyboardActor;
        const win = global.display.focus_window;
        const vis = !!(actor && actor.visible);
        const text = [
            `ver=${VERSION}`,
            `visible=${vis}`,
            `user=${this._userRequested}`,
            `await=${this._awaitContent}`,
            `title=${win ? win.get_title() : ''}`,
            `wm=${win ? win.get_wm_class() : ''}`,
            `actorOpen=${!!actor?._daguActorOpen}`,
            `actor_open=${!!actor?._daguInternalOpen}`,
            `mgrGate=${!!Main.keyboard?._daguOpenGate}`,
            '',
        ].join('\n');
        try {
            Gio.File.new_for_path('/tmp/dagu-osk.status').replace_contents(
                new TextEncoder().encode(text),
                null, false, Gio.FileCreateFlags.REPLACE_DESTINATION, null);
        } catch (e) {
        }
    }

    _connect(obj, sig, cb) {
        this._conns.push([obj, obj.connect(sig, cb)]);
    }

    _connectVis() {
        const actor = Main.keyboard?.keyboardActor;
        if (!actor || this._visId)
            return;
        this._visId = actor.connect('visibility-changed', () => {
            this._log(`vis=${actor.visible} user=${this._userRequested} chrome=${this._isChrome()}`);
            if (actor.visible && this._isChrome() && !this._userRequested)
                this._close('vis-unrequested');
            this._writeStatus();
        });
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
            this._log(`title=${this._trackedWin.get_title()}`);
            this._close('title');
        });
    }

    _winLabel() {
        const win = global.display.focus_window;
        if (!win)
            return 'none';
        const bits = [
            win.get_wm_class?.(),
            win.get_wm_class_instance?.(),
            win.get_gtk_application_id?.(),
            win.get_sandboxed_app_id?.(),
            win.get_title?.(),
        ].filter(Boolean);
        try {
            const pid = win.get_pid();
            bits.push(`pid=${pid}`);
            const [ok, data] = Gio.File.new_for_path(`/proc/${pid}/comm`)
                .load_contents(null);
            if (ok)
                bits.push(new TextDecoder().decode(data).trim());
        } catch (e) {
        }
        return bits.join('|');
    }

    _isChrome() {
        return /chrome|chromium/i.test(this._winLabel());
    }

    _chromeZone(event) {
        const win = global.display.focus_window;
        if (!win || !this._isChrome())
            return 'other';
        const [x, y] = this._eventXY(event);
        const rect = win.get_frame_rect();
        if (x < rect.x || x > rect.x + rect.width ||
            y < rect.y || y > rect.y + rect.height)
            return 'other';
        // Tab strip / close-tab (~36-48px). Omnibox sits in the next band.
        const tabH = Math.max(64, Math.round(rect.height * 0.055));
        if (y <= rect.y + tabH)
            return 'toolbar';
        const boxH = Math.max(170, Math.round(rect.height * 0.15));
        if (y <= rect.y + boxH)
            return 'omnibox';
        return 'content';
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

    _onPointer(event) {
        const type = event.type();
        if (type !== Clutter.EventType.TOUCH_BEGIN &&
            type !== Clutter.EventType.BUTTON_PRESS)
            return;
        const zone = this._chromeZone(event);
        const [x, y] = this._eventXY(event);
        this._log(`tap zone=${zone} xy=${Math.round(x)},${Math.round(y)}`);
        this._awaitContent = false;
        if (zone === 'omnibox') {
            this._requestOpen('omnibox-tap');
            return;
        }
        if (zone !== 'content') {
            this._close(`tap-${zone}`);
            return;
        }
        this._awaitContent = true;
        if (this._closeTimeout)
            GLib.source_remove(this._closeTimeout);
        this._closeTimeout = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 450, () => {
            this._closeTimeout = 0;
            if (this._awaitContent) {
                this._awaitContent = false;
                this._close('content-miss');
            }
            return GLib.SOURCE_REMOVE;
        });
    }

    _requestOpen(why) {
        if (this._closeTimeout) {
            GLib.source_remove(this._closeTimeout);
            this._closeTimeout = 0;
        }
        this._awaitContent = false;
        if (this._openTimeout)
            GLib.source_remove(this._openTimeout);
        this._log(`request ${why}`);
        this._openTimeout = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 30, () => {
            this._openTimeout = 0;
            this._open();
            return GLib.SOURCE_REMOVE;
        });
    }

    _wrapFn(obj, key, flag, fn) {
        if (!obj || obj[flag])
            return;
        obj[flag] = obj[key].bind(obj);
        obj[key] = fn;
    }

    _gateAllOpens() {
        const mgr = Main.keyboard;
        if (mgr && !mgr._daguOpenGate) {
            mgr._daguOpenGate = true;
            this._origMgrOpen = mgr.open.bind(mgr);
            mgr.open = monitor => {
                if (this._isChrome() && !this._userRequested) {
                    this._log('block mgr.open');
                    return;
                }
                this._origMgrOpen(monitor);
            };
            if (typeof mgr.close === 'function')
                this._origMgrClose = mgr.close.bind(mgr);
        }
        const actor = mgr?.keyboardActor;
        if (!actor)
            return;
        this._wrapFn(actor, 'open', '_daguActorOpen', immediate => {
            if (this._isChrome() && !this._userRequested) {
                this._log('block actor.open');
                return;
            }
            actor._daguActorOpen(immediate);
        });
        this._wrapFn(actor, '_open', '_daguInternalOpen', () => {
            if (this._isChrome() && !this._userRequested) {
                this._log('block actor._open');
                return;
            }
            actor._daguInternalOpen();
        });
        if (!actor._daguRelayout) {
            const origRelayout = actor._relayout.bind(actor);
            actor._daguRelayout = true;
            actor._relayout = () => {
                origRelayout();
                const mon = Main.layoutManager.keyboardMonitor;
                if (!mon)
                    return;
                actor.width = mon.width;
                if (mon.width > mon.height)
                    actor.height = Math.round(Math.min(mon.height * 0.46, 380));
            };
        }
        this._connectVis();
    }

    _open() {
        this._gateAllOpens();
        this._userRequested = true;
        this._log('open');
        try {
            const idx = Main.layoutManager.focusIndex;
            Main.layoutManager.keyboardIndex = idx;
            if (this._origMgrOpen)
                this._origMgrOpen(idx);
            else
                Main.keyboard?.open(idx);
            const actor = Main.keyboard?.keyboardActor;
            actor?._relayout?.();
            actor?._daguInternalOpen?.();
        } catch (e) {
            this._log(`open-err ${e}`);
        }
        if (this._expireTimeout)
            GLib.source_remove(this._expireTimeout);
        this._expireTimeout = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 180, () => {
            this._expireTimeout = 0;
            this._userRequested = false;
            this._writeStatus();
            return GLib.SOURCE_REMOVE;
        });
        this._writeStatus();
    }

    _cancelActorTimers() {
        const actor = Main.keyboard?.keyboardActor;
        try {
            actor?._clearKeyboardRestTimer?.();
        } catch (e) {
        }
        try {
            actor?._clearShowIdle?.();
        } catch (e) {
        }
    }

    _close(why) {
        if (this._openTimeout) {
            GLib.source_remove(this._openTimeout);
            this._openTimeout = 0;
        }
        this._awaitContent = false;
        this._userRequested = false;
        this._cancelActorTimers();
        const actor = Main.keyboard?.keyboardActor;
        const was = !!(actor && actor.visible);
        try {
            actor?.close?.(true);
        } catch (e) {
        }
        try {
            if (this._origMgrClose)
                this._origMgrClose();
            else
                Main.keyboard?.close?.();
        } catch (e) {
        }
        if (was || why)
            this._log(`close ${why || ''} was=${was}`);
        this._writeStatus();
    }

    disable() {
        if (this._openTimeout)
            GLib.source_remove(this._openTimeout);
        if (this._closeTimeout)
            GLib.source_remove(this._closeTimeout);
        if (this._expireTimeout)
            GLib.source_remove(this._expireTimeout);
        this._openTimeout = 0;
        this._closeTimeout = 0;
        this._expireTimeout = 0;
        const actor = Main.keyboard?.keyboardActor;
        if (actor) {
            if (this._visId) {
                try {
                    actor.disconnect(this._visId);
                } catch (e) {
                }
            }
            if (actor._daguActorOpen) {
                actor.open = actor._daguActorOpen;
                delete actor._daguActorOpen;
            }
            if (actor._daguInternalOpen) {
                actor._open = actor._daguInternalOpen;
                delete actor._daguInternalOpen;
            }
        }
        this._visId = 0;
        if (this._trackedWin && this._winTitleId) {
            try {
                this._trackedWin.disconnect(this._winTitleId);
            } catch (e) {
            }
        }
        this._winTitleId = 0;
        this._trackedWin = null;
        const mgr = Main.keyboard;
        if (mgr?._daguOpenGate && this._origMgrOpen) {
            mgr.open = this._origMgrOpen;
            mgr._daguOpenGate = false;
        }
        for (const [obj, id] of this._conns)
            obj.disconnect(id);
        this._conns = [];
        this._log(`${VERSION} disable`);
    }
}
