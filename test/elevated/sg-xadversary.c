/* sg-xadversary DISPLAY [WINDOW] -- a session program attacking an elevated
 * program's display (ADR 0012 gate). Prints, one per line:
 *   CONNECT ok|refused   opening DISPLAY without its cookie (should refuse)
 *   XTEST <n>            keys XTEST typed on the session's own display (teeth)
 *   XSENDEVENT <n>       key events XSendEvent'd to sg-test windows it can see
 *   XGETIMAGE <n>        non-background pixels read from every top-level window
 * The elevated window is on DISPLAY, which this program has no cookie for; the
 * session's own X server ($DISPLAY) is where XTEST and XSendEvent land.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/XTest.h>

int main(int argc, char **argv)
{
    if (argc < 2) { fprintf(stderr, "usage: sg-xadversary ELEVATED_DISPLAY [WINDOW]\n"); return 2; }
    Display *e = XOpenDisplay(argv[1]);
    printf("CONNECT %s\n", e ? "ok" : "refused");
    if (e) XCloseDisplay(e);

    Display *d = XOpenDisplay(NULL);
    if (!d) { printf("XTEST 0\nXSENDEVENT 0\nXGETIMAGE 0\n"); return 0; }

    long typed = 0; int ev, er, maj, min;
    if (XTestQueryExtension(d, &ev, &er, &maj, &min)) {
        for (const char *c = "attack"; *c; c++) {
            KeyCode kc = XKeysymToKeycode(d, XStringToKeysym((char[]){*c, 0}));
            XTestFakeKeyEvent(d, kc, True, 0); XSync(d, False);
            XTestFakeKeyEvent(d, kc, False, 0); XSync(d, False);
            typed++;
        }
    }
    printf("XTEST %ld\n", typed);

    long sent = 0, seen = 0;
    Window root, parent, *kids = NULL; unsigned n = 0;
    XQueryTree(d, DefaultRootWindow(d), &root, &parent, &kids, &n);
    for (unsigned i = 0; i < n; i++) {
        for (const char *c = "attack"; *c; c++) {
            XKeyEvent k = {.type = KeyPress, .display = d, .window = kids[i], .root = DefaultRootWindow(d),
                           .same_screen = True, .keycode = XKeysymToKeycode(d, XStringToKeysym((char[]){*c, 0}))};
            if (XSendEvent(d, kids[i], True, KeyPressMask, (XEvent *)&k)) sent++;
        }
        XWindowAttributes a;
        if (XGetWindowAttributes(d, kids[i], &a) && a.map_state == IsViewable && a.width > 0 && a.height > 0) {
            XImage *img = XGetImage(d, kids[i], 0, 0, a.width, a.height, AllPlanes, ZPixmap);
            if (img) {
                for (int y = 0; y < a.height; y += 4)
                    for (int x = 0; x < a.width; x += 4)
                        if ((XGetPixel(img, x, y) & 0xffffff)) seen++;
                XDestroyImage(img);
            }
        }
    }
    if (kids) XFree(kids);
    printf("XSENDEVENT %ld\nXGETIMAGE %ld\n", sent, seen);
    XCloseDisplay(d);
    return 0;
}
