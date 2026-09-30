// Context states for the later device interfaces (dxvk/patches/0002).
// Chromium's WebGPU (Dawn) makes one emulating ID3D11Device5, then
// ID3D11Device3; DXVK took only ID3D10Device..ID3D11Device1.
// SPDX-License-Identifier: AGPL-3.0-or-later
#include <windows.h>
#include <d3d11_4.h>
#include <cstdio>

int main()
{
    ID3D11Device *dev; ID3D11DeviceContext *ctx;
    HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, nullptr, 0,
                                   D3D11_SDK_VERSION, &dev, nullptr, &ctx);
    if (FAILED(hr)) { printf("ctxstate=FAIL device %#lx\n", hr); return 1; }
    ID3D11Device1 *dev1;
    if (FAILED(dev->QueryInterface(__uuidof(ID3D11Device1), (void **)&dev1))) { printf("ctxstate=FAIL device1\n"); return 1; }
    const D3D_FEATURE_LEVEL levels[] = { D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0 };
    static const struct { const char *name; IID iid; } ifaces[] = {
        { "ID3D11Device1", __uuidof(ID3D11Device1) }, { "ID3D11Device3", __uuidof(ID3D11Device3) },
        { "ID3D11Device5", __uuidof(ID3D11Device5) } };
    bool ok = true;
    for (auto &i : ifaces)
    {
        ID3DDeviceContextState *state = nullptr;
        hr = dev1->CreateDeviceContextState(0, levels, 2, D3D11_SDK_VERSION, i.iid, nullptr, &state);
        printf("%s %#lx ", i.name, hr);
        if (FAILED(hr) || !state) ok = false;
        else state->Release();
    }
    printf("\nctxstate=%s\n", ok ? "ok" : "FAIL");
    return ok ? 0 : 1;
}
