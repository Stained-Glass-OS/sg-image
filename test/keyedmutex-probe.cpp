// keyedmutex-probe: a D3D11 texture shared between two processes under its keyed mutex, as
// Chromium (Qt WebEngine) shares frames from its GPU process: NT handle, SHARED_KEYEDMUTEX.
// The parent draws (ClearRenderTargetView, on the GPU) red, releases key 1; the child acquires
// key 1, reads the pixel, releases key 0; the parent acquires key 0, draws green, releases 1; the
// child acquires 1 and reads again. Prints KEY=1 per check.
//   keyedmutex-probe.exe            (parent; starts itself as the child)
#define INITGUID
#include <windows.h>
#include <d3d11_1.h>
#include <dxgi1_2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static ID3D11Device *dev;
static ID3D11DeviceContext *ctx;

static DWORD read_pixel(ID3D11Texture2D *t)
{
    D3D11_TEXTURE2D_DESC d;
    ID3D11Texture2D *s;
    D3D11_MAPPED_SUBRESOURCE m;
    DWORD px = 0xdeadbeef;
    t->GetDesc(&d);
    d.Usage = D3D11_USAGE_STAGING; d.BindFlags = 0; d.CPUAccessFlags = D3D11_CPU_ACCESS_READ; d.MiscFlags = 0;
    if (FAILED(dev->CreateTexture2D(&d, NULL, &s))) return px;
    ctx->CopyResource(s, t);
    if (SUCCEEDED(ctx->Map(s, 0, D3D11_MAP_READ, 0, &m)))
    {
        px = ((DWORD *)((BYTE *)m.pData + 5 * m.RowPitch))[5];
        ctx->Unmap(s, 0);
    }
    s->Release();
    return px;
}

int main(int argc, char **argv)
{
    UINT flags = 0;
    if (FAILED(D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, flags, NULL, 0, D3D11_SDK_VERSION, &dev, NULL, &ctx)))
    {
        printf("FAIL device\n");
        return 1;
    }
    if (argc > 2 && !strcmp(argv[1], "child"))
    {
        HANDLE h = (HANDLE)(ULONG_PTR)strtoull(argv[2], NULL, 16);
        ID3D11Device1 *dev1;
        ID3D11Texture2D *t;
        IDXGIKeyedMutex *km;
        HRESULT hr;
        DWORD px;
        dev->QueryInterface(IID_ID3D11Device1, (void **)&dev1);
        hr = dev1->OpenSharedResource1(h, IID_ID3D11Texture2D, (void **)&t);
        printf("child open %08lx\n", hr);
        if (FAILED(hr) || FAILED(t->QueryInterface(IID_IDXGIKeyedMutex, (void **)&km))) { printf("child_open=0\n"); return 0; }
        printf("child_open=1\n"); fflush(stdout);
        hr = km->AcquireSync(1, 10000);
        px = read_pixel(t);
        printf("child acquire1 %08lx pixel %08lx\nred=%d\n", hr, px, hr == S_OK && px == 0xffff0000);
        printf("child release0 %08lx\n", km->ReleaseSync(0)); fflush(stdout);
        hr = km->AcquireSync(1, 10000);
        px = read_pixel(t);
        printf("child acquire1 %08lx pixel %08lx\ngreen=%d\n", hr, px, hr == S_OK && px == 0xff00ff00);
        km->ReleaseSync(0);
        return 0;
    }
    {
        D3D11_TEXTURE2D_DESC d = { 64, 64, 1, 1, DXGI_FORMAT_B8G8R8A8_UNORM, { 1, 0 }, D3D11_USAGE_DEFAULT,
                                   D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET, 0,
                                   D3D11_RESOURCE_MISC_SHARED_NTHANDLE | D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX };
        static const float red[4] = { 1, 0, 0, 1 }, green[4] = { 0, 1, 0, 1 };
        SECURITY_ATTRIBUTES sa = { sizeof(sa), NULL, TRUE };
        STARTUPINFOA si = { sizeof(si) };
        PROCESS_INFORMATION pi;
        ID3D11Texture2D *t;
        ID3D11RenderTargetView *rtv;
        IDXGIResource1 *r1;
        IDXGIKeyedMutex *km;
        HANDLE h = NULL;
        HRESULT hr;
        char cmd[600];
        DWORD code = 1;

        hr = dev->CreateTexture2D(&d, NULL, &t);
        printf("parent texture %08lx\n", hr);
        if (FAILED(hr)) { printf("texture=0\n"); return 0; }
        t->QueryInterface(IID_IDXGIResource1, (void **)&r1);
        t->QueryInterface(IID_IDXGIKeyedMutex, (void **)&km);
        hr = r1->CreateSharedHandle(&sa, DXGI_SHARED_RESOURCE_READ | DXGI_SHARED_RESOURCE_WRITE, NULL, &h);
        printf("parent share %08lx\nshare=%d\n", hr, hr == S_OK && h);
        dev->CreateRenderTargetView(t, NULL, &rtv);

        hr = km->AcquireSync(0, 10000);
        ctx->ClearRenderTargetView(rtv, red);
        printf("parent acquire0 %08lx release1 %08lx\n", hr, km->ReleaseSync(1));
        fflush(stdout);
        sprintf(cmd, "\"%s\" child %Ix", argv[0], (ULONG_PTR)h);
        if (!CreateProcessA(NULL, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) { printf("FAIL spawn\n"); return 1; }
        hr = km->AcquireSync(0, 15000);
        ctx->ClearRenderTargetView(rtv, green);
        printf("parent acquire0 %08lx release1 %08lx\nparent_turn=%d\n", hr, km->ReleaseSync(1), hr == S_OK);
        fflush(stdout);
        if (WaitForSingleObject(pi.hProcess, 20000)) TerminateProcess(pi.hProcess, 1);
        GetExitCodeProcess(pi.hProcess, &code);
        printf("child_exit=%d\n", code == 0);
        hr = km->AcquireSync(0, 10000);
        printf("parent acquire0 %08lx own pixel %08lx\nparent_green=%d\n", hr, read_pixel(t), hr == S_OK && read_pixel(t) == 0xff00ff00);
        km->ReleaseSync(1);
        printf("done=1\n");
    }
    return 0;
}
