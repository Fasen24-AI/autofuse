#!/usr/bin/env python3
"""AutoFuse — Linux GUI (GTK4).

A small window that lists every configured machine with its IP and mount
status, and lets you mount / unmount / connect / wake each one. It is a thin
front-end over the `autofuse` CLI (which is itself a wrapper over the shared
bash engine) — the CLI is the single source of truth, exactly like the macOS
menu-bar app. No tray host required, so it works on any Wayland/X11 desktop
(Hyprland included).

Requires: gtk4, python-gobject, and `autofuse` on PATH.
"""

import json
import shutil
import subprocess
import threading

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gtk, GLib, Gio  # noqa: E402

CLI = shutil.which("autofuse") or "autofuse"


def run_cli(args, timeout=120):
    """Run `autofuse <args>`; return (rc, stdout, stderr). Never raises."""
    try:
        p = subprocess.run(
            [CLI, *args],
            capture_output=True,
            text=True,
            timeout=timeout,
            stdin=subprocess.DEVNULL,
        )
        return p.returncode, p.stdout, p.stderr
    except FileNotFoundError:
        return 127, "", f"`autofuse` not found on PATH ({CLI})"
    except subprocess.TimeoutExpired:
        return 124, "", "operation timed out"
    except Exception as e:  # defensive: the GUI must never crash on a CLI hiccup
        return 1, "", str(e)


def load_machines():
    """Merge `autofuse json list` + `json status` into a per-machine view.

    Returns (machines, error). machines = [{name, ip, mounted, total, status}].
    """
    rc, out, err = run_cli(["json", "list"])
    if rc != 0:
        return [], (err.strip() or "could not read machine list")
    try:
        listing = json.loads(out or "[]")
    except json.JSONDecodeError:
        return [], "malformed machine list from CLI"

    status_rows = []
    rc, out, _ = run_cli(["json", "status"])
    if rc == 0:
        try:
            status_rows = json.loads(out or "[]")
        except json.JSONDecodeError:
            status_rows = []

    by_ws = {}
    for r in status_rows:
        by_ws.setdefault(r.get("workstation"), []).append(r.get("status", ""))

    machines = []
    for m in listing:
        name = m.get("name", "")
        statuses = by_ws.get(name, [])
        total = len(m.get("disks", [])) or len(statuses)
        mounted = sum(1 for s in statuses if s == "mounted")
        if any(s == "stale" for s in statuses):
            state = "stale"
        elif total and mounted == total:
            state = "mounted"
        elif mounted:
            state = "partial"
        else:
            state = "unmounted"
        machines.append(
            {
                "name": name,
                "ip": m.get("lan_ip") or m.get("vpn_ip") or "",
                "mounted": mounted,
                "total": total,
                "status": state,
            }
        )
    return machines, None


STATUS_COLOR = {
    "mounted": "#34c759",
    "partial": "#ffcc00",
    "stale": "#ff9500",
    "unmounted": "#8e8e93",
}


class AutoFuseWindow(Gtk.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="AutoFuse")
        self.set_default_size(460, 520)
        self._busy = False

        header = Gtk.HeaderBar()
        self.set_titlebar(header)
        refresh = Gtk.Button(icon_name="view-refresh-symbolic")
        refresh.set_tooltip_text("Refresh")
        refresh.connect("clicked", lambda *_: self.refresh())
        header.pack_end(refresh)

        self.status_label = Gtk.Label(label="")
        self.status_label.add_css_class("dim-label")
        header.pack_start(self.status_label)

        scroller = Gtk.ScrolledWindow()
        scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroller.set_vexpand(True)
        self.listbox = Gtk.ListBox()
        self.listbox.set_selection_mode(Gtk.SelectionMode.NONE)
        self.listbox.add_css_class("boxed-list")
        self.listbox.set_margin_top(12)
        self.listbox.set_margin_bottom(12)
        self.listbox.set_margin_start(12)
        self.listbox.set_margin_end(12)
        scroller.set_child(self.listbox)
        self.set_child(scroller)

        self.refresh()

    # ── rendering ──────────────────────────────────────────────────────────
    def refresh(self):
        self.status_label.set_text("loading…")
        threading.Thread(target=self._refresh_worker, daemon=True).start()

    def _refresh_worker(self):
        machines, error = load_machines()
        GLib.idle_add(self._render, machines, error)

    def _render(self, machines, error):
        child = self.listbox.get_first_child()
        while child:
            nxt = child.get_next_sibling()
            self.listbox.remove(child)
            child = nxt

        if error:
            self.status_label.set_text("error")
            self.listbox.append(self._message_row(error))
            return
        if not machines:
            self.status_label.set_text("")
            self.listbox.append(
                self._message_row("No machines configured.\nAdd one with: autofuse add")
            )
            return

        self.status_label.set_text(f"{len(machines)} machines")
        for m in machines:
            self.listbox.append(self._machine_row(m))
        return False

    def _message_row(self, text):
        row = Gtk.ListBoxRow()
        lbl = Gtk.Label(label=text)
        lbl.set_margin_top(24)
        lbl.set_margin_bottom(24)
        lbl.add_css_class("dim-label")
        lbl.set_justify(Gtk.Justification.CENTER)
        row.set_child(lbl)
        return row

    def _machine_row(self, m):
        row = Gtk.ListBoxRow()
        box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        box.set_margin_top(8)
        box.set_margin_bottom(8)
        box.set_margin_start(10)
        box.set_margin_end(10)

        dot = Gtk.Label(label="●")
        color = STATUS_COLOR.get(m["status"], "#8e8e93")
        dot.set_markup(f'<span foreground="{color}">●</span>')
        box.append(dot)

        info = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        info.set_hexpand(True)
        name = Gtk.Label(xalign=0)
        name.set_markup(f"<b>{GLib.markup_escape_text(m['name'])}</b>")
        sub = Gtk.Label(xalign=0)
        sub.add_css_class("dim-label")
        sub.set_markup(
            f"<small>{GLib.markup_escape_text(m['ip'])}  ·  "
            f"{m['mounted']}/{m['total']} mounted</small>"
        )
        info.append(name)
        info.append(sub)
        box.append(info)

        if m["status"] in ("mounted", "partial", "stale"):
            box.append(self._action(m["name"], "Unmount", "unmount"))
        if m["status"] != "mounted":
            box.append(self._action(m["name"], "Connect", "connect", suggested=True))

        row.set_child(box)
        return row

    def _action(self, ws, label, cmd, suggested=False):
        btn = Gtk.Button(label=label)
        if suggested:
            btn.add_css_class("suggested-action")
        btn.set_valign(Gtk.Align.CENTER)
        btn.connect("clicked", lambda *_: self._run_action(ws, cmd))
        return btn

    # ── actions ────────────────────────────────────────────────────────────
    def _run_action(self, ws, cmd):
        if self._busy:
            return
        self._busy = True
        self.status_label.set_text(f"{cmd} {ws}…")

        def worker():
            run_cli([cmd, ws])
            GLib.idle_add(self._action_done)

        threading.Thread(target=worker, daemon=True).start()

    def _action_done(self):
        self._busy = False
        self.refresh()
        return False


class AutoFuseApp(Gtk.Application):
    def __init__(self):
        super().__init__(
            application_id="com.fasen24.autofuse",
            flags=Gio.ApplicationFlags.DEFAULT_FLAGS,
        )

    def do_activate(self):
        win = self.props.active_window or AutoFuseWindow(self)
        win.present()


if __name__ == "__main__":
    AutoFuseApp().run(None)
