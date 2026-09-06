/* Runs the actual native IStream facade without touching the OS clipboard.
 * Rust transport hooks are replaced by a deterministic byte source. */
#include <assert.h>
#include <string.h>
#include "../libs/clipboard/src/windows/wf_cliprdr.c"

static unsigned reads, releases;
UINT64 mdesk_clipboard_remote_generation(UINT32 conn) { return 77; }
void mdesk_clipboard_source_snapshot(UINT32 sequence, UINT32 count, WCHAR **paths) {}
HANDLE mdesk_clipboard_descriptors(UINT32 conn, UINT64 gen, UINT32 format, SIZE_T *size)
{
    *size = sizeof(FILEGROUPDESCRIPTORW);
    HANDLE handle = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, *size);
    FILEGROUPDESCRIPTORW *group = GlobalLock(handle);
    group->cItems = 1;
    group->fgd[0].dwFlags = FD_FILESIZE;
    group->fgd[0].nFileSizeLow = 100;
    wcscpy_s(group->fgd[0].cFileName, MAX_PATH, L"test.bin");
    GlobalUnlock(handle);
    return handle;
}
int mdesk_clipboard_stream_read(UINT32 conn, UINT64 gen, UINT32 index, UINT64 size,
    UINT64 offset, void *output, UINT32 requested, UINT32 *read, UINT64 *token)
{
    UINT32 n = requested < size - offset ? requested : (UINT32)(size - offset);
    assert(conn == 3 && gen == 77 && index == 2);
    for (UINT32 i = 0; i < n; i++) ((BYTE *)output)[i] = (BYTE)(offset + i);
    *read = n; *token = 99; reads++;
    return 0;
}
void mdesk_clipboard_stream_release(UINT32 conn, UINT64 token)
{ assert(conn == 3 && token == 99); releases++; }

static void native_read_seek_eof_and_release(void)
{
    wfClipboard cb = {0};
    FILEDESCRIPTORW descriptor = {0};
    descriptor.dwFlags = FD_FILESIZE; descriptor.nFileSizeLow = 100;
    CliprdrStream *stream = CliprdrStream_New(3, 77, 2, &cb, &descriptor);
    assert(stream);
    BYTE data[80]; ULONG n;
    assert(IStream_Read((IStream *)stream, data, 80, &n) == S_OK && n == 80);
    for (unsigned i = 0; i < n; i++) assert(data[i] == i);
    assert(IStream_Read((IStream *)stream, data, 80, &n) == S_FALSE && n == 20);
    assert(data[0] == 80 && data[19] == 99);
    assert(IStream_Read((IStream *)stream, data, 1, &n) == S_FALSE && n == 0);
    assert(reads == 2);
    LARGE_INTEGER move; move.QuadPart = -10;
    assert(IStream_Seek((IStream *)stream, move, STREAM_SEEK_END, NULL) == S_OK);
    assert(IStream_Read((IStream *)stream, data, 10, &n) == S_OK && data[0] == 90);
    IStream_Release((IStream *)stream);
    assert(releases == 1);
}

static void legacy_response_correlation(void)
{
    wfClipboard cb = {0}; CliprdrClientContext context = {0};
    context.Custom = &cb; cb.context = &context;
    InitializeSRWLock(&cb.req_response_lock);
    cb.req_fevent = CreateEvent(NULL, TRUE, FALSE, NULL);
    cb.req_waiting = TRUE; cb.req_conn = 10; cb.req_serial = 21; cb.req_limit = 3;
    const BYTE data[] = {1, 2, 3};
    CLIPRDR_FILE_CONTENTS_RESPONSE reply = {0};
    reply.connID = 11; reply.streamId = 21; reply.msgFlags = CB_RESPONSE_OK;
    reply.cbRequested = 3; reply.requestedData = data;
    assert(wf_cliprdr_server_file_contents_response(&context, &reply) == CHANNEL_RC_OK);
    assert(cb.req_waiting && !cb.req_fdata && WaitForSingleObject(cb.req_fevent, 0) == WAIT_TIMEOUT);
    reply.connID = 10; reply.streamId = 20;
    wf_cliprdr_server_file_contents_response(&context, &reply);
    assert(cb.req_waiting && !cb.req_fdata);
    reply.streamId = 21;
    assert(wf_cliprdr_server_file_contents_response(&context, &reply) == CHANNEL_RC_OK);
    assert(!cb.req_waiting && cb.req_fsize == 3 && !memcmp(cb.req_fdata, data, 3));
    assert(WaitForSingleObject(cb.req_fevent, 0) == WAIT_OBJECT_0);
    free(cb.req_fdata); cb.req_fdata = NULL;
    ResetEvent(cb.req_fevent);
    wf_cliprdr_server_file_contents_response(&context, &reply);
    assert(!cb.req_fdata && WaitForSingleObject(cb.req_fevent, 0) == WAIT_TIMEOUT);
    cb.req_waiting = TRUE; cb.req_serial = 22; reply.streamId = 22; reply.cbRequested = 4;
    assert(wf_cliprdr_server_file_contents_response(&context, &reply) != CHANNEL_RC_OK);
    assert(!cb.req_fdata && WaitForSingleObject(cb.req_fevent, 0) == WAIT_OBJECT_0);
    CloseHandle(cb.req_fevent);
}

static void native_descriptor_ownership_survives_new_copy(void)
{
    wfClipboard cb = {0}; IDataObject *object = NULL;
    FILE_OBJECT_REQUEST request = {3, 77, 123};
    /* An acquired generation does not depend on the latest global copied flag. */
    cb.copied = FALSE;
    HANDLE unrelated = GlobalAlloc(GMEM_MOVEABLE, 16);
    cb.hmem = unrelated; cb.hmem_data_len = 16;
    assert(wf_create_file_obj(&request, &cb, &object));
    FORMATETC format = {0}; STGMEDIUM first = {0}, second = {0};
    format.cfFormat = RegisterClipboardFormat(CFSTR_FILEDESCRIPTORW);
    format.dwAspect = DVASPECT_CONTENT; format.tymed = TYMED_HGLOBAL; format.lindex = -1;
    assert(IDataObject_GetData(object, &format, &first) == S_OK);
    assert(IDataObject_GetData(object, &format, &second) == S_OK);
    assert(first.hGlobal != second.hGlobal);
    assert(cb.hmem == unrelated && cb.hmem_data_len == 16);
    IDataObject_Release(object);
    /* OLE owns both handles, independently of the descriptor object's lifetime. */
    assert(GlobalSize(first.hGlobal) >= sizeof(FILEGROUPDESCRIPTORW));
    ReleaseStgMedium(&first); ReleaseStgMedium(&second); GlobalFree(unrelated);
}
int main(void)
{
    native_read_seek_eof_and_release();
    legacy_response_correlation();
    native_descriptor_ownership_survives_new_copy();
    puts("native clipboard tests passed: IStream read/seek/EOF/release, descriptor ownership, legacy response isolation");
    return 0;
}
