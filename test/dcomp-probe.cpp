// A composition swap chain shows in its window (dxvk/patches/0001).
// A window; a Direct3D 11 device; CreateSwapChainForComposition; a
// DirectComposition target for the window with a visual whose content is the
// swap chain; the back buffer cleared red and presented. Prints "dcomp=ok"
// when the window's centre is red on the screen, "dcomp=FAIL <stage>" if not.
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <dcomp.h>
#include <cstdio>

int main()
{
    WNDCLASSA wc = {};
    wc.lpfnWndProc = DefWindowProcA; wc.lpszClassName = "SgDcompProbe";
    wc.hbrBackground = (HBRUSH)GetStockObject(WHITE_BRUSH);
    RegisterClassA(&wc);
    HWND hwnd = CreateWindowExA(WS_EX_NOREDIRECTIONBITMAP, "SgDcompProbe", "dcomp", WS_POPUP | WS_VISIBLE,
                                100, 100, 256, 256, 0, 0, 0, 0);
    UpdateWindow(hwnd);

    ID3D11Device *dev; ID3D11DeviceContext *ctx;
    HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                                   nullptr, 0, D3D11_SDK_VERSION, &dev, nullptr, &ctx);
    if (FAILED(hr)) { printf("dcomp=FAIL device %#lx\n", hr); return 1; }
    IDXGIDevice *dxgidev; IDXGIAdapter *adapter; IDXGIFactory2 *factory;
    dev->QueryInterface(__uuidof(IDXGIDevice), (void **)&dxgidev);
    dxgidev->GetAdapter(&adapter);
    adapter->GetParent(__uuidof(IDXGIFactory2), (void **)&factory);

    DXGI_SWAP_CHAIN_DESC1 desc = {};
    desc.Width = 256; desc.Height = 256; desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1; desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT; desc.BufferCount = 2;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL; desc.AlphaMode = DXGI_ALPHA_MODE_PREMULTIPLIED;
    IDXGISwapChain1 *sc;
    if (FAILED(hr = factory->CreateSwapChainForComposition(dev, &desc, nullptr, &sc)))
    { printf("dcomp=FAIL swapchain %#lx\n", hr); return 1; }

    IDCompositionDevice *dcomp; IDCompositionTarget *target; IDCompositionVisual *visual;
    if (FAILED(hr = DCompositionCreateDevice(dxgidev, __uuidof(IDCompositionDevice), (void **)&dcomp)))
    { printf("dcomp=FAIL dcompdevice %#lx\n", hr); return 1; }
    dcomp->CreateTargetForHwnd(hwnd, TRUE, &target);
    dcomp->CreateVisual(&visual);
    visual->SetContent(sc);
    target->SetRoot(visual);
    dcomp->Commit();

    ID3D11Texture2D *bb; ID3D11RenderTargetView *rtv;
    sc->GetBuffer(0, __uuidof(ID3D11Texture2D), (void **)&bb);
    dev->CreateRenderTargetView(bb, nullptr, &rtv);
    const float red[4] = { 1.0f, 0.0f, 0.0f, 1.0f };
    for (int i = 0; i < 20; i++)
    {
        MSG msg;
        ctx->ClearRenderTargetView(rtv, red);
        sc->Present(1, 0);
        while (PeekMessageA(&msg, 0, 0, 0, PM_REMOVE)) DispatchMessageA(&msg);
        Sleep(50);
    }
    HDC dc = GetDC(nullptr);
    COLORREF c = GetPixel(dc, 228, 228);
    ReleaseDC(nullptr, dc);
    bool ok = GetRValue(c) > 200 && GetGValue(c) < 60 && GetBValue(c) < 60;
    printf(ok ? "dcomp=ok %06lx\n" : "dcomp=FAIL pixel %06lx\n", c);
    return ok ? 0 : 1;
}
