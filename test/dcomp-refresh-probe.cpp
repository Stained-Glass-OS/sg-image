// Composition swap chains made through DXVK stay shown (dxvk/patches/0003).
//
//  half    - a 16-bit float swap chain (R16G16B16A16_FLOAT, linear values),
//            cleared red and presented, shows red: Paint.NET's canvas and
//            History/Layers lists are such swap chains;
//  commit  - a swap chain presented once, then painted over on its window
//            (as Windows.UI.Composition's target clears the window before it
//            places its swap chains, and as WM_PAINT does): DirectComposition's
//            next Commit shows the frame again at once;
//  refresh - painted over and not presented again: the frame is back within
//            a second.
//
// Prints "name=ok|FAIL <pixel>" lines.
// SPDX-License-Identifier: AGPL-3.0-or-later
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <dcomp.h>
#include <cstdio>

static HWND make_window(int x)
{
    HWND hwnd = CreateWindowExA(WS_EX_NOREDIRECTIONBITMAP, "SgDcompRefresh", "dcomp", WS_POPUP | WS_VISIBLE,
                                x, 100, 200, 200, 0, 0, 0, 0);
    UpdateWindow(hwnd);
    return hwnd;
}

static void pump(int ms)
{
    DWORD end = GetTickCount() + ms;
    do {
        MSG msg;
        while (PeekMessageA(&msg, 0, 0, 0, PM_REMOVE)) DispatchMessageA(&msg);
        Sleep(10);
    } while ((int)(end - GetTickCount()) > 0);
}

static COLORREF screen_pixel(int x, int y)
{
    HDC dc = GetDC(nullptr);
    COLORREF c = GetPixel(dc, x, y);
    ReleaseDC(nullptr, dc);
    return c;
}

static void paint_over(HWND hwnd)
{
    HDC dc = GetDC(hwnd);
    RECT r = { 0, 0, 200, 200 };
    FillRect(dc, &r, (HBRUSH)GetStockObject(WHITE_BRUSH));
    ReleaseDC(hwnd, dc);
}

struct chain
{
    IDXGISwapChain1 *sc;
    IDCompositionDevice *dcomp;
    ID3D11RenderTargetView *rtv;
};

static bool make_chain(ID3D11Device *dev, IDXGIDevice *dxgidev, IDXGIFactory2 *factory, HWND hwnd,
                       DXGI_FORMAT format, chain *c)
{
    DXGI_SWAP_CHAIN_DESC1 desc = {};
    desc.Width = 200; desc.Height = 200; desc.Format = format;
    desc.SampleDesc.Count = 1; desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT; desc.BufferCount = 2;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL; desc.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
    HRESULT hr;
    if (FAILED(hr = factory->CreateSwapChainForComposition(dev, &desc, nullptr, &c->sc)))
    { printf("swapchain=FAIL %#lx\n", hr); return false; }
    IDCompositionTarget *target; IDCompositionVisual *visual;
    if (FAILED(hr = DCompositionCreateDevice(dxgidev, __uuidof(IDCompositionDevice), (void **)&c->dcomp)))
    { printf("dcompdevice=FAIL %#lx\n", hr); return false; }
    c->dcomp->CreateTargetForHwnd(hwnd, TRUE, &target);
    c->dcomp->CreateVisual(&visual);
    visual->SetContent(c->sc);
    target->SetRoot(visual);
    c->dcomp->Commit();
    ID3D11Texture2D *bb;
    c->sc->GetBuffer(0, __uuidof(ID3D11Texture2D), (void **)&bb);
    dev->CreateRenderTargetView(bb, nullptr, &c->rtv);
    return true;
}

static bool is(COLORREF c, int r, int g, int b)
{
    return abs((int)GetRValue(c) - r) < 40 && abs((int)GetGValue(c) - g) < 40 && abs((int)GetBValue(c) - b) < 40;
}

int main()
{
    WNDCLASSA wc = {};
    wc.lpfnWndProc = DefWindowProcA; wc.lpszClassName = "SgDcompRefresh";
    wc.hbrBackground = (HBRUSH)GetStockObject(WHITE_BRUSH);
    RegisterClassA(&wc);

    ID3D11Device *dev; ID3D11DeviceContext *ctx;
    HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                                   nullptr, 0, D3D11_SDK_VERSION, &dev, nullptr, &ctx);
    if (FAILED(hr)) { printf("device=FAIL %#lx\n", hr); return 1; }
    IDXGIDevice *dxgidev; IDXGIAdapter *adapter; IDXGIFactory2 *factory;
    dev->QueryInterface(__uuidof(IDXGIDevice), (void **)&dxgidev);
    dxgidev->GetAdapter(&adapter);
    adapter->GetParent(__uuidof(IDXGIFactory2), (void **)&factory);

    /* half: linear 1,0,0 is sRGB red */
    {
        HWND hwnd = make_window(20);
        chain c;
        if (!make_chain(dev, dxgidev, factory, hwnd, DXGI_FORMAT_R16G16B16A16_FLOAT, &c)) return 1;
        const float red[4] = { 1.0f, 0.0f, 0.0f, 1.0f };
        ctx->ClearRenderTargetView(c.rtv, red);
        c.sc->Present(0, 0);
        pump(300);
        COLORREF px = screen_pixel(120, 200);
        printf("half=%s %06lx\n", is(px, 255, 0, 0) ? "ok" : "FAIL", px);
    }
    /* commit and refresh: green, painted over */
    {
        HWND hwnd = make_window(300);
        chain c;
        if (!make_chain(dev, dxgidev, factory, hwnd, DXGI_FORMAT_B8G8R8A8_UNORM, &c)) return 1;
        const float green[4] = { 0.0f, 1.0f, 0.0f, 1.0f };
        ctx->ClearRenderTargetView(c.rtv, green);
        c.sc->Present(0, 0);
        pump(1500);   /* any refresh due from the present is over */
        paint_over(hwnd);
        pump(80);     /* the white reaches the screen */
        COLORREF before = screen_pixel(400, 200);
        c.dcomp->Commit();
        pump(80);
        COLORREF after = screen_pixel(400, 200);
        printf("commit=%s %06lx (painted over: %06lx)\n", is(before, 255, 255, 255) && is(after, 0, 255, 0) ? "ok" : "FAIL",
               after, before);
        pump(1500);
        paint_over(hwnd);
        pump(1500);   /* not presented again: drawn again by itself */
        after = screen_pixel(400, 200);
        printf("refresh=%s %06lx\n", is(after, 0, 255, 0) ? "ok" : "FAIL", after);
    }
    return 0;
}
