import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

// Chrome text-input-v3 calls enable() but never show_input_panel.
// Mutter 50 only raises the OSK on show_input_panel (or a v1 double-enable).
// Cursor updates mean a client really has a text field; open the system OSK.
export default class DaguOskFocus extends Extension {
    enable() {
        this._im = Main.inputMethod;
        this._ids = [
            this._im.connect('notify::current-focus', () => {
                if (this._im.currentFocus)
                    this._open();
            }),
            this._im.connect('cursor-location-changed', () => this._open()),
        ];
    }

    _open() {
        Main.keyboard?.open(Main.layoutManager.focusIndex);
    }

    disable() {
        for (const id of this._ids)
            this._im.disconnect(id);
        this._ids = [];
    }
}
