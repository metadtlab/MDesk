/* Runs the actual native IStream facade without touching the OS clipboard.
 * Rust transport hooks are replaced by a deterministic byte source. */
#include <assert.h>
#include <stdlib.h>
#include <string.h>
static int fail_next_realloc;
static void *test_realloc(void *ptr, size_t size)
{
    if (fail_next_realloc) { fail_next_realloc = 0; return NULL; }
    return realloc(ptr, size);
}
#define realloc test_realloc
#include "../libs/clipboard/src/windows/wf_cliprdr.c"
#undef realloc

static unsigned reads, releases;
UINT64 mdesk_clipboard_remote_generation(UINT32 conn) { return 77; }
HANDLE mdesk_clipboard_find_first_file(const WCHAR *path, WIN32_FIND_DATAW *data)
{ return FindFirstFileW(path, data); }
HANDLE mdesk_clipboard_open_file_for_read(const WCHAR *path)
{
    return CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS, NULL);
}
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
static void format_map_growth_and_rejection(void)
{
    wfClipboard cb = {0}; CliprdrClientContext context = {0};
    context.Custom = &cb; cb.context = &context;
    cb.map_capacity = 32;
    cb.format_mappings = calloc(cb.map_capacity, sizeof(formatMapping));
    assert(cb.format_mappings);

    assert(map_ensure_capacity(&cb, 33));
    for (size_t i = 0; i < cb.map_capacity; i++)
        assert(!cb.format_mappings[i].name && cb.format_mappings[i].local_format_id == 0);
    assert(!map_ensure_capacity(&cb, WF_CLIPRDR_MAX_FORMATS + 1));

    CLIPRDR_FORMAT formats[34] = {0};
    CLIPRDR_FORMAT_LIST list = {0};
    list.formats = formats; list.numFormats = 34;
    fail_next_realloc = 1;
    assert(wf_cliprdr_server_format_list(&context, &list) != CHANNEL_RC_OK);
    assert(!fail_next_realloc && cb.map_size == 0 && cb.map_capacity == 33 && !cb.copied);

    list.numFormats = WF_CLIPRDR_MAX_FORMATS + 1;
    assert(wf_cliprdr_server_format_list(&context, &list) != CHANNEL_RC_OK);
    list.numFormats = 1; list.formats = NULL;
    assert(wf_cliprdr_server_format_list(&context, &list) != CHANNEL_RC_OK);

    list.formats = formats;
    formats[0].formatName = "";
    assert(wf_cliprdr_server_format_list(&context, &list) != CHANNEL_RC_OK);
    char long_name[WF_CLIPRDR_MAX_FORMAT_NAME_UTF8_BYTES + 2];
    memset(long_name, 'a', sizeof(long_name));
    long_name[sizeof(long_name) - 1] = 0;
    formats[0].formatName = long_name;
    assert(wf_cliprdr_server_format_list(&context, &list) != CHANNEL_RC_OK);
    long_name[256] = 0;
    assert(wf_cliprdr_server_format_list(&context, &list) != CHANNEL_RC_OK);
    assert(cb.map_size == 0 && !cb.copied);

    list.numFormats = 2;
    formats[0].formatName = "MDeskSecurityTestFormat";
    formats[1].formatName = "";
    assert(wf_cliprdr_server_format_list(&context, &list) != CHANNEL_RC_OK);
    assert(cb.map_size == 0 && !cb.copied);
    for (size_t i = 0; i < cb.map_capacity; i++)
        assert(!cb.format_mappings[i].name);

    size_t length = 0;
    long_name[255] = 0;
    assert(wf_cliprdr_bounded_strlen(long_name, 255, &length) && length == 255);
    assert(!wf_cliprdr_bounded_strlen(long_name, 254, &length));
    assert(!wf_cliprdr_bounded_strlen(NULL, 255, &length));
    assert(clear_format_map(&cb));
    free(cb.format_mappings);
}

int main(void)
{
    native_read_seek_eof_and_release();
    legacy_response_correlation();
    native_descriptor_ownership_survives_new_copy();
    format_map_growth_and_rejection();
    puts("native clipboard tests passed: streams, descriptor ownership, response isolation, format limits and allocation failure");
    return 0;
}
