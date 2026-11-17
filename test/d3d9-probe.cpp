// d3d9-probe: Direct3D 9 through the DXVK built here (sg-d3d now builds d3d9.dll from source, with
// patches) -- for test/d3d9-test.sh. A D3D9Ex device on a window: a clear, a triangle drawn with
// DrawPrimitiveUP, an NV12 surface written with LockRect and stretched onto the render target, each
// read back with GetRenderTargetData; then Present. Prints one line:
// "d3d9=ok clear=RRGGBB draw=RRGGBB nv12=RRGGBB" or "FAIL <step> 0x<hr>".
#include <windows.h>
#include <d3d9.h>
#include <cstdio>
#include <cstring>

static IDirect3DDevice9Ex* dev;
static IDirect3DSurface9 *rt, *sysmem;

static unsigned centre() {
  D3DLOCKED_RECT lr;
  if (FAILED(dev->GetRenderTargetData(rt, sysmem)) || FAILED(sysmem->LockRect(&lr, nullptr, D3DLOCK_READONLY)))
    return 0xdeadbeef;
  unsigned px = ((const unsigned*)((const char*)lr.pBits + lr.Pitch * 32))[32] & 0xffffff;
  sysmem->UnlockRect();
  return px;
}

int main() {
  HWND wnd = CreateWindowA("STATIC", "d3d9", WS_POPUP, 0, 0, 64, 64, nullptr, nullptr, nullptr, nullptr);
  IDirect3D9Ex* d3d = nullptr;
  HRESULT hr = Direct3DCreate9Ex(D3D_SDK_VERSION, &d3d);
  if (FAILED(hr)) { printf("FAIL create 0x%08lx\n", hr); return 0; }
  D3DPRESENT_PARAMETERS pp = { };
  pp.BackBufferWidth = 64; pp.BackBufferHeight = 64; pp.BackBufferFormat = D3DFMT_X8R8G8B8;
  pp.BackBufferCount = 1; pp.SwapEffect = D3DSWAPEFFECT_DISCARD; pp.hDeviceWindow = wnd; pp.Windowed = TRUE;
  hr = d3d->CreateDeviceEx(D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, wnd, D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, nullptr, &dev);
  if (FAILED(hr)) { printf("FAIL device 0x%08lx\n", hr); return 0; }
  dev->GetRenderTarget(0, &rt);
  dev->CreateOffscreenPlainSurface(64, 64, D3DFMT_X8R8G8B8, D3DPOOL_SYSTEMMEM, &sysmem, nullptr);

  dev->Clear(0, nullptr, D3DCLEAR_TARGET, D3DCOLOR_XRGB(255, 0, 0), 1.0f, 0);
  unsigned clear = centre();

  struct V { float x, y, z, rhw; DWORD c; } tri[3] = {
    { -64.f, -64.f, 0.f, 1.f, D3DCOLOR_XRGB(0, 255, 0) },
    { 192.f, -64.f, 0.f, 1.f, D3DCOLOR_XRGB(0, 255, 0) },
    { -64.f, 192.f, 0.f, 1.f, D3DCOLOR_XRGB(0, 255, 0) } };
  dev->BeginScene();
  dev->SetRenderState(D3DRS_LIGHTING, FALSE);
  dev->SetRenderState(D3DRS_CULLMODE, D3DCULL_NONE);
  dev->SetFVF(D3DFVF_XYZRHW | D3DFVF_DIFFUSE);
  hr = dev->DrawPrimitiveUP(D3DPT_TRIANGLELIST, 1, tri, sizeof(V));
  dev->EndScene();
  if (FAILED(hr)) { printf("FAIL draw 0x%08lx\n", hr); return 0; }
  unsigned draw = centre();

  // an NV12 surface (what DXVA2 decodes into): blue in BT.601 video range, stretched onto the target
  IDirect3DSurface9* nv12 = nullptr;
  hr = dev->CreateOffscreenPlainSurface(64, 64, (D3DFORMAT)MAKEFOURCC('N', 'V', '1', '2'), D3DPOOL_DEFAULT, &nv12, nullptr);
  if (FAILED(hr)) { printf("FAIL nv12 0x%08lx\n", hr); return 0; }
  D3DLOCKED_RECT lr;
  if (FAILED(hr = nv12->LockRect(&lr, nullptr, 0))) { printf("FAIL nv12lock 0x%08lx\n", hr); return 0; }
  for (int y = 0; y < 64; y++) memset((char*)lr.pBits + lr.Pitch * y, 41, 64);
  for (int y = 0; y < 32; y++) {
    unsigned char* row = (unsigned char*)lr.pBits + lr.Pitch * (64 + y);
    for (int x = 0; x < 32; x++) { row[2 * x] = 240; row[2 * x + 1] = 110; }
  }
  nv12->UnlockRect();
  if (FAILED(hr = dev->StretchRect(nv12, nullptr, rt, nullptr, D3DTEXF_NONE))) { printf("FAIL stretch 0x%08lx\n", hr); return 0; }
  unsigned yuv = centre();

  hr = dev->PresentEx(nullptr, nullptr, nullptr, nullptr, 0);
  printf("d3d9=%s clear=%06x draw=%06x nv12=%06x\n", SUCCEEDED(hr) ? "ok" : "nopresent", clear, draw, yuv);
  return 0;
}
