# GTK at a fractional display scale

David, 2026-10-05: "For the scaling it'd be nice if we could get it to work
where GTK can fractionally scale … It's okay if we have to patch GTK too. Top
of the line DPI scaling is what we were going for."

## The problem

Linux programs run as X11 clients of Xwayland, inside the Wine desktop's
frames (winex11 `sg_embed`). The compositor's outputs stay at scale 1 (else
Xwayland, and with it Wine, would be stretched), so each toolkit scales
itself. Qt 5 and 6 take any factor from `Xft/DPI` (sg-session sets
`QT_ENABLE_HIGHDPI_SCALING=1`, `QT_SCALE_FACTOR_ROUNDING_POLICY=PassThrough`).
GTK on X11 knows only whole numbers (`GDK_SCALE`, the XSETTINGS
`Gdk/WindowScalingFactor`): at 175% (a Surface Pro 7) GTK programs were drawn
at 200%, their text corrected to 175% with `Gdk/UnscaledDPI` but their
widgets, padding and icons 14% too large.

## The two ways considered

1. **Native Wayland clients** of sg-compositor, with `wp_fractional_scale_v1`
   and `wp_viewporter` (GTK 4 and Qt 6 scale fractionally there, GTK 3 draws
   at the next whole step and is scaled down by the compositor). Rejected:
   Linux windows must stack among Wine's windows, carry Wine frames, taskbar
   buttons, Alt+Tab and Task View cards, snap, maximize above the taskbar and
   take focus as Windows windows do; all of that is built on their being X
   windows Wine reparents (`sg_embed`, `XDESKTOP`). Native Wayland toplevels
   sit above the whole Wine desktop (the reason sg-session forces
   `GDK_BACKEND=x11`), and GTK 3 would still be blurred by downscaling.
2. **Patch GTK's X11 backend** so a window's scale may be fractional, driven
   by the session's XSETTINGS manager. Chosen: everything else keeps working
   unchanged, and both GTK 3 and GTK 4 draw at the exact scale.

## What the patches do (gtk-scale/*.patch)

- The XSETTINGS manager publishes `Gdk/SgFractionalScale`, the scale in
  1024ths (1792 at 175%; sg-session's `sg_xsettings_conf`, above 100% only).
  Debian's GTK ignores the unknown name.
- GDK's X11 backend keeps the window scale as a double: an X window is the
  logical size times the scale (sizes round up, positions round), events
  are divided by it, monitors and the work area are in logical pixels, and
  the text's DPI is `Xft/DPI` over the scale (so text is exactly the scale,
  not twice). With a whole-number scale every expression is GTK's own, so
  100% and 200% are untouched.
- GTK 4 already draws at any scale (GSK, as on Wayland); its buffer is the
  X window's own size.
- GTK 3 draws through cairo at the fractional device scale (crisp text and
  shapes); `gdk_window_get_scale_factor()` returns the next whole step, so
  images and icons are made at 2x and drawn smaller. OpenGL painting is read
  back through cairo at a fractional scale.
- Programs that draw into their X windows themselves by GDK's whole-number
  factor -- Firefox, Thunderbird, Emacs, LibreOffice -- are told scale 1 and
  the whole DPI (they scale themselves by it: Firefox and Thunderbird take
  1.75 from 168 DPI). `GDK_SG_FRACTIONAL=0` puts any program in that group,
  `=1` none.
- A change while programs run (Settings > Display > Scale) is followed at
  once, as for Debian's GTK's whole steps.

## Packaging

`gtk-scale/build-debs.sh gtk3|gtk4` rebuilds Debian's current `gtk+3.0` or
`gtk4` source with the patch as its last quilt patch, version
`<Debian's>+sg<date of Debian's changelog entry>.<REV>` -- above Debian's
(also above a `+deb13uN` security update of the same base), and a later
Debian update gives a later date. Each release builds from Debian's current
source, so a security update is taken by the next release; unchanged
inputs come from the cache. `libgtk-3-0t64` and `libgtk-3-common` (installed
in the image) are staged for the image; every other binary package of the
two sources goes to the apt repository only (`$(BUILD)/repo-only`), so
machines that install GTK 4 programs, or have `gir1.2-gtk-3.0` or the -dev
packages, get matching versions. The test is `test/gtk-scale-test.sh`.

## 32-bit (i386) GTK: not built -- decided 2026-10-06

Not built, on purpose. The image is amd64 only, with no i386 multiarch
(mkosi.conf, ADR 0002): our Wine runs 32-bit Windows programs without it
(`--enable-archs=i386,x86_64`), and nothing in the image, the Store or
sg-session uses an i386 GTK. Steam, the one program people add i386 for,
takes the 32-bit libraries it needs but not GTK 3 (`steam-libs-i386`
suggests GTK 2 only; its portal Recommends is satisfied by the amd64
`xdg-desktop-portal-gtk`, and Recommends are not installed here anyway).

What happens if someone adds i386 and asks for `libgtk-3-0t64:i386` all the
same: the package is Multi-Arch: same, so both architectures must be one
version, and Debian has no i386 build of ours. apt says so (an unmet
dependency or a conflict) and changes nothing; installing it means taking
the amd64 GTK back to Debian's version too
(`apt install libgtk-3-0t64:i386 libgtk-3-0t64=<Debian's version> libgtk-3-common=<Debian's version>`),
and the machine's GTK programs are then at the whole-step scale (200% at
175%) as with Debian's GTK. If a program ever needs i386 GTK 3,
`gtk-scale/build-debs.sh` can build the same patched source for i386 in an
i386 chroot (the patch is architecture-independent); the cost is a second
full GTK 3 build per release.

## Limits

- i386 GTK is not built (above): a machine that adds i386 GTK 3 must take
  both architectures back to Debian's version (`libgtk-3-0t64` is
  Multi-Arch: same).
- Programs in the self-scaling group are at the whole scale's text and
  their own layout, not GTK's fractional one.
- A program that reads `gdk_window_get_scale_factor()` and draws bitmaps
  itself gets them at the next whole step, drawn smaller: sharp, a little
  soft, the right size.
