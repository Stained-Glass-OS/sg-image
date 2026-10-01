/* Wine's mshtml with Wine Gecko (sg-wine-gecko): an HTML document is written
 * and its body's text read back. Without Gecko mshtml cannot load a
 * document. Prints "text=<body text>". */
#define COBJMACROS
#include <windows.h>
#include <mshtml.h>
#include <stdio.h>

static const GUID clsid_htmldocument = { 0x25336920, 0x03f9, 0x11cf, { 0x8f, 0xd0, 0x00, 0xaa, 0x00, 0x68, 0x6f, 0x13 } };

int main(void)
{
    IHTMLDocument2 *doc;
    IHTMLElement *body = NULL;
    SAFEARRAY *sa;
    VARIANT *v;
    BSTR text = NULL;
    HRESULT hr;

    CoInitialize(NULL);
    hr = CoCreateInstance(&clsid_htmldocument, NULL, CLSCTX_INPROC_SERVER, &IID_IHTMLDocument2, (void **)&doc);
    if (FAILED(hr)) { printf("create=%#lx\n", hr); return 1; }
    sa = SafeArrayCreateVector(VT_VARIANT, 0, 1);
    SafeArrayAccessData(sa, (void **)&v);
    V_VT(v) = VT_BSTR;
    V_BSTR(v) = SysAllocString(L"<html><body><p>stained glass gecko</p></body></html>");
    SafeArrayUnaccessData(sa);
    hr = IHTMLDocument2_write(doc, sa);
    printf("write=%#lx\n", hr);
    IHTMLDocument2_close(doc);
    if (SUCCEEDED(IHTMLDocument2_get_body(doc, &body)) && body) IHTMLElement_get_innerText(body, &text);
    printf("text=%ls\n", text ? text : L"");
    {   /* which engine: the packaged one, not another Gecko on the machine */
        WCHAR path[MAX_PATH] = L"";
        HMODULE xul = GetModuleHandleW(L"xul.dll");
        if (xul) GetModuleFileNameW(xul, path, MAX_PATH);
        printf("xul=%ls\n", path);
    }
    return 0;
}
