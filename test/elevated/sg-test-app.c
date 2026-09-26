/* The program sg-test-setup.exe installs (sg-image elevated-display gate). */
#include <windows.h>
int WINAPI wWinMain(HINSTANCE i, HINSTANCE p, PWSTR c, int s)
{
    (void)i; (void)p; (void)c; (void)s;
    MessageBoxW(NULL, L"SG Test App is installed.", L"SG Test App", MB_OK);
    return 0;
}
