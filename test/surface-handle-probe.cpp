// A composition swap chain for a DirectComposition surface handle, through
// DXVK (dxvk/patches/0004). Windows Terminal's renderer makes its swap chain
// with IDXGIFactoryMedia::CreateSwapChainForCompositionSurfaceHandle and hands
// the handle to a XAML SwapChainPanel, which finds the swap chain through the
// factory's IWineDXGISurfaceHandles (wine-sg's XAML) and shows it. The probe
// does both halves: a surface handle from DCompositionCreateSurfaceHandle, the
// swap chain (unscaled, as Windows Terminal's) cleared red and presented, then
// the swap chain found by the handle and placed in a window. Prints
// "surface=ok" when the window shows red; "surface=FAIL <stage>" if not.
#include <windows.h>
#include <initguid.h>
#include <d3d11.h>
#include <dxgi1_3.h>
#include <dcomp.h>
#include <cstdio>

// wine-sg's private interfaces (include/wine/winedxgi.idl)
DEFINE_GUID(IID_IWineDXGICompositionSwapChain, 0x7c3f5d2e, 0x9a41, 0x4b8e, 0xb6, 0xd3, 0x2f, 0x0e, 0x8a, 0x1c, 0x5b, 0x94);
DEFINE_GUID(IID_IWineDXGISurfaceHandles, 0xb5d3ad91, 0x81e3, 0x409d, 0x84, 0xda, 0x01, 0x80, 0x7c, 0x20, 0xad, 0x13);
struct IWineDXGICompositionSwapChain : public IUnknown
{
    virtual HRESULT STDMETHODCALLTYPE set_target(HWND window, int x, int y) = 0;
};
struct IWineDXGISurfaceHandles : public IUnknown
{
    virtual HRESULT STDMETHODCALLTYPE swapchain_from_handle(HANDLE handle, IWineDXGICompositionSwapChain **swapchain) = 0;
};

typedef HRESULT (WINAPI *create_surface_handle_fn)(DWORD, SECURITY_ATTRIBUTES *, HANDLE *);

int main()
{
    WNDCLASSA wc = {};
    wc.lpfnWndProc = DefWindowProcA; wc.lpszClassName = "SgSurfaceProbe";
    wc.hbrBackground = (HBRUSH)GetStockObject(WHITE_BRUSH);
    RegisterClassA(&wc);
    HWND hwnd = CreateWindowExA(0, "SgSurfaceProbe", "surface", WS_POPUP | WS_VISIBLE, 100, 100, 256, 256, 0, 0, 0, 0);
    UpdateWindow(hwnd);

    ID3D11Device *dev; ID3D11DeviceContext *ctx;
    HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
                                   nullptr, 0, D3D11_SDK_VERSION, &dev, nullptr, &ctx);
    if (FAILED(hr)) { printf("surface=FAIL device %#lx\n", hr); return 1; }
    IDXGIDevice *dxgidev; IDXGIAdapter *adapter; IDXGIFactory2 *factory;
    dev->QueryInterface(__uuidof(IDXGIDevice), (void **)&dxgidev);
    dxgidev->GetAdapter(&adapter);
    adapter->GetParent(__uuidof(IDXGIFactory2), (void **)&factory);

    HMODULE dcomp = LoadLibraryA("dcomp.dll");
    create_surface_handle_fn create_handle = dcomp ? (create_surface_handle_fn)GetProcAddress(dcomp, "DCompositionCreateSurfaceHandle") : nullptr;
    HANDLE surface = nullptr;
    if (!create_handle || FAILED(hr = create_handle(3, nullptr, &surface)))
    { printf("surface=FAIL handle %#lx\n", create_handle ? hr : E_NOTIMPL); return 1; }

    IDXGIFactoryMedia *media;
    if (FAILED(hr = factory->QueryInterface(__uuidof(IDXGIFactoryMedia), (void **)&media)))
    { printf("surface=FAIL media %#lx\n", hr); return 1; }
    DXGI_SWAP_CHAIN_DESC1 desc = {};
    desc.Width = 256; desc.Height = 256; desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1; desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT; desc.BufferCount = 3;
    desc.Scaling = DXGI_SCALING_NONE; desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
    desc.AlphaMode = DXGI_ALPHA_MODE_IGNORE; desc.Flags = DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT;
    IDXGISwapChain1 *sc;
    if (FAILED(hr = media->CreateSwapChainForCompositionSurfaceHandle(dev, surface, &desc, nullptr, &sc)))
    { printf("surface=FAIL swapchain %#lx\n", hr); return 1; }
    IDXGISwapChain2 *sc2;
    HANDLE latency = SUCCEEDED(sc->QueryInterface(__uuidof(IDXGISwapChain2), (void **)&sc2)) ? sc2->GetFrameLatencyWaitableObject() : nullptr;
    if (!latency) { printf("surface=FAIL latency\n"); return 1; }

    // the consumer's half: the swap chain found by the handle, shown in the window
    IWineDXGISurfaceHandles *handles; IWineDXGICompositionSwapChain *target;
    if (FAILED(hr = factory->QueryInterface(IID_IWineDXGISurfaceHandles, (void **)&handles)))
    { printf("surface=FAIL handles %#lx\n", hr); return 1; }
    if (FAILED(hr = handles->swapchain_from_handle(surface, &target)))
    { printf("surface=FAIL find %#lx\n", hr); return 1; }

    ID3D11Texture2D *bb; ID3D11RenderTargetView *rtv;
    sc->GetBuffer(0, __uuidof(ID3D11Texture2D), (void **)&bb);
    dev->CreateRenderTargetView(bb, nullptr, &rtv);
    const float red[4] = { 1.0f, 0.0f, 0.0f, 1.0f };
    for (int i = 0; i < 20; i++)
    {
        MSG msg;
        WaitForSingleObject(latency, 1000);
        ctx->ClearRenderTargetView(rtv, red);
        sc->Present(1, 0);
        target->set_target(hwnd, 0, 0);
        while (PeekMessageA(&msg, 0, 0, 0, PM_REMOVE)) DispatchMessageA(&msg);
        Sleep(50);
    }
    HDC dc = GetDC(nullptr);
    COLORREF c = GetPixel(dc, 228, 228);
    ReleaseDC(nullptr, dc);
    bool ok = GetRValue(c) > 200 && GetGValue(c) < 60 && GetBValue(c) < 60;
    printf(ok ? "surface=ok %06lx\n" : "surface=FAIL pixel %06lx\n", c);
    return ok ? 0 : 1;
}
