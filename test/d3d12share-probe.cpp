// d3d12share-probe: a texture made and drawn by Direct3D 11 in one process, opened and read by
// Direct3D 12 in another (Chromium's frames into Qt's D3D12 renderer).
//   d3d12share-probe.exe [km]   (parent; km adds SHARED_KEYEDMUTEX; starts itself as the child)
// Prints KEY=1 per check: share, open, red, green, child_exit, done.
#define INITGUID
#include <windows.h>
#include <d3d11_1.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int child(HANDLE h, HANDLE go, HANDLE done)
{
    ID3D12Device *dev;
    ID3D12CommandQueue *q;
    ID3D12CommandAllocator *alloc;
    ID3D12GraphicsCommandList *list;
    ID3D12Resource *tex, *rb;
    ID3D12Fence *fence;
    HRESULT hr;
    int round;
    if (FAILED(hr = D3D12CreateDevice(NULL, D3D_FEATURE_LEVEL_11_0, IID_ID3D12Device, (void **)&dev)))
    { printf("FAIL d3d12 device %08lx\n", hr); return 1; }
    hr = dev->OpenSharedHandle(h, IID_ID3D12Resource, (void **)&tex);
    printf("child OpenSharedHandle %08lx\nopen=%d\n", hr, hr == S_OK);
    if (FAILED(hr)) return 0;
    D3D12_RESOURCE_DESC d = tex->GetDesc();
    printf("child desc %ux%u format %d dim %d layout %d flags %x\n", (unsigned)d.Width, d.Height, d.Format, d.Dimension, d.Layout, d.Flags);
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp; UINT64 total;
    dev->GetCopyableFootprints(&d, 0, 1, 0, &fp, NULL, NULL, &total);
    D3D12_HEAP_PROPERTIES hp = { D3D12_HEAP_TYPE_READBACK };
    D3D12_RESOURCE_DESC bd = { D3D12_RESOURCE_DIMENSION_BUFFER, 0, total, 1, 1, 1, DXGI_FORMAT_UNKNOWN, { 1, 0 }, D3D12_TEXTURE_LAYOUT_ROW_MAJOR, D3D12_RESOURCE_FLAG_NONE };
    dev->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &bd, D3D12_RESOURCE_STATE_COPY_DEST, NULL, IID_ID3D12Resource, (void **)&rb);
    D3D12_COMMAND_QUEUE_DESC qd = { D3D12_COMMAND_LIST_TYPE_DIRECT };
    dev->CreateCommandQueue(&qd, IID_ID3D12CommandQueue, (void **)&q);
    dev->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_ID3D12CommandAllocator, (void **)&alloc);
    dev->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_ID3D12Fence, (void **)&fence);
    for (round = 0; round < 2; round++)
    {
        DWORD want = round ? 0xff00ff00 : 0xffff0000, px = 0xdeadbeef;
        void *p;
        if (WaitForSingleObject(go, 15000)) { printf("child: no signal\n"); return 1; }
        alloc->Reset();
        dev->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, alloc, NULL, IID_ID3D12GraphicsCommandList, (void **)&list);
        D3D12_RESOURCE_BARRIER b = { D3D12_RESOURCE_BARRIER_TYPE_TRANSITION };
        b.Transition.pResource = tex; b.Transition.Subresource = 0;
        b.Transition.StateBefore = D3D12_RESOURCE_STATE_COMMON; b.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
        list->ResourceBarrier(1, &b);
        D3D12_TEXTURE_COPY_LOCATION dst = { rb, D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT }, src = { tex, D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX };
        dst.PlacedFootprint = fp; src.SubresourceIndex = 0;
        list->CopyTextureRegion(&dst, 0, 0, 0, &src, NULL);
        b.Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_SOURCE; b.Transition.StateAfter = D3D12_RESOURCE_STATE_COMMON;
        list->ResourceBarrier(1, &b);
        list->Close();
        q->ExecuteCommandLists(1, (ID3D12CommandList **)&list);
        q->Signal(fence, round + 1);
        while (fence->GetCompletedValue() < (UINT64)round + 1) Sleep(1);
        if (SUCCEEDED(rb->Map(0, NULL, &p)))
        { px = ((DWORD *)((BYTE *)p + 5 * fp.Footprint.RowPitch))[5]; rb->Unmap(0, NULL); }
        printf("child round %d pixel %08lx\n%s=%d\n", round, px, round ? "green" : "red", px == want);
        fflush(stdout);
        list->Release();
        SetEvent(done);
    }
    return 0;
}

int main(int argc, char **argv)
{
    if (argc > 4 && !strcmp(argv[1], "child"))
        return child((HANDLE)(ULONG_PTR)strtoull(argv[2], NULL, 16), (HANDLE)(ULONG_PTR)strtoull(argv[3], NULL, 16),
                     (HANDLE)(ULONG_PTR)strtoull(argv[4], NULL, 16));
    {
        int km = argc > 1 && !strcmp(argv[1], "km");
        ID3D11Device *dev; ID3D11DeviceContext *ctx; ID3D11Texture2D *t; ID3D11RenderTargetView *rtv;
        IDXGIResource1 *r1; IDXGIKeyedMutex *mutex = NULL; ID3D11Query *ev; HANDLE h = NULL; HRESULT hr;
        SECURITY_ATTRIBUTES sa = { sizeof(sa), NULL, TRUE };
        HANDLE go = CreateEventA(&sa, FALSE, FALSE, NULL), done = CreateEventA(&sa, FALSE, FALSE, NULL);
        STARTUPINFOA si = { sizeof(si) }; PROCESS_INFORMATION pi; char cmd[600]; DWORD code = 1;
        static const float red[4] = { 1, 0, 0, 1 }, green[4] = { 0, 1, 0, 1 };
        D3D11_TEXTURE2D_DESC d = { 64, 64, 1, 1, DXGI_FORMAT_B8G8R8A8_UNORM, { 1, 0 }, D3D11_USAGE_DEFAULT,
            D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET, 0,
            (UINT)(D3D11_RESOURCE_MISC_SHARED_NTHANDLE | (km ? D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX : D3D11_RESOURCE_MISC_SHARED)) };
        D3D11_QUERY_DESC qd = { D3D11_QUERY_EVENT, 0 };
        if (FAILED(D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION, &dev, NULL, &ctx)))
        { printf("FAIL device\n"); return 1; }
        hr = dev->CreateTexture2D(&d, NULL, &t);
        printf("parent texture %08lx (%s)\n", hr, km ? "keyed mutex" : "no mutex");
        if (FAILED(hr)) return 0;
        t->QueryInterface(IID_IDXGIResource1, (void **)&r1);
        if (km) t->QueryInterface(IID_IDXGIKeyedMutex, (void **)&mutex);
        hr = r1->CreateSharedHandle(&sa, DXGI_SHARED_RESOURCE_READ | DXGI_SHARED_RESOURCE_WRITE, NULL, &h);
        printf("parent share %08lx\nshare=%d\n", hr, hr == S_OK && h);
        dev->CreateRenderTargetView(t, NULL, &rtv);
        dev->CreateQuery(&qd, &ev);
        sprintf(cmd, "\"%s\" child %Ix %Ix %Ix", argv[0], (ULONG_PTR)h, (ULONG_PTR)go, (ULONG_PTR)done);
        if (!CreateProcessA(NULL, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) { printf("FAIL spawn\n"); return 1; }
        for (int round = 0; round < 2; round++)
        {
            if (mutex) mutex->AcquireSync(0, 10000);
            ctx->ClearRenderTargetView(rtv, round ? green : red);
            ctx->End(ev); ctx->Flush();
            while (ctx->GetData(ev, NULL, 0, 0) == S_FALSE) Sleep(1);
            if (mutex) mutex->ReleaseSync(0);
            SetEvent(go);
            if (WaitForSingleObject(done, 20000)) { printf("parent: child did not read\n"); break; }
        }
        if (WaitForSingleObject(pi.hProcess, 20000)) TerminateProcess(pi.hProcess, 1);
        GetExitCodeProcess(pi.hProcess, &code);
        printf("child_exit=%d\ndone=1\n", code == 0);
    }
    return 0;
}
