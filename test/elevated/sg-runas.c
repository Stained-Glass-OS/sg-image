/* sg-runas EXE [ARG] -- ShellExecute "runas" on EXE, the way "Run as
 * administrator" does, and wait. For the elevated-display gate: it launches
 * the installer so its requireAdministrator manifest reaches the elevation
 * broker (ADR 0012), which prompts on the secure surface. */
#include <windows.h>
int WINAPI wWinMain(HINSTANCE i, HINSTANCE p, PWSTR cmd, int show)
{
    (void)i; (void)p; (void)show;
    int argc; LPWSTR *argv = CommandLineToArgvW(cmd, &argc);
    if (!argv || argc < 1) return 2;
    SHELLEXECUTEINFOW sei = { sizeof(sei) };
    sei.fMask = SEE_MASK_NOCLOSEPROCESS;
    sei.lpVerb = L"runas";
    sei.lpFile = argv[0];
    sei.lpParameters = argc > 1 ? argv[1] : NULL;
    sei.nShow = SW_SHOWNORMAL;
    if (!ShellExecuteExW(&sei)) return 1;
    if (sei.hProcess) { WaitForSingleObject(sei.hProcess, INFINITE); CloseHandle(sei.hProcess); }
    return 0;
}
