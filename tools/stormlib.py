"""
StormLib ctypes wrapper for MPQ archive operations.
Auto-downloads prebuilt StormLib from GitHub releases if not found locally.
"""

import ctypes
from ctypes import c_bool, c_char_p, c_uint32, c_uint64, c_void_p, byref, POINTER
from pathlib import Path
import platform

SCRIPT_DIR = Path(__file__).parent
LIB_DIR = SCRIPT_DIR / "lib"

STORMLIB_VERSION = "v9.31"
STORMLIB_RELEASE_URL = f"https://github.com/ladislav-zezula/StormLib/releases/download/{STORMLIB_VERSION}"


def _download_stormlib():
    """Download prebuilt StormLib for the current platform."""
    import urllib.request
    import ssl
    import tempfile
    import shutil
    import subprocess

    system = platform.system().lower()
    machine = platform.machine().lower()

    LIB_DIR.mkdir(parents=True, exist_ok=True)

    if system == "linux" and machine in ("x86_64", "amd64"):
        lib_name = "libstorm.so"
        deb_name = f"libstorm-dev_{STORMLIB_VERSION}_amd64.deb"
        url = f"{STORMLIB_RELEASE_URL}/{deb_name}"
        lib_path = LIB_DIR / lib_name

        print(f"Downloading StormLib {STORMLIB_VERSION}...")
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir = Path(tmpdir)
            pkg_path = tmpdir / "stormlib.deb"
            req = urllib.request.Request(url, headers={"User-Agent": "M2Editor/1.0"})
            # Try default SSL first, fall back to unverified if certs missing
            try:
                ctx = ssl.create_default_context()
                resp_obj = urllib.request.urlopen(req, timeout=60, context=ctx)
            except ssl.SSLCertVerificationError:
                ctx = ssl.create_default_context()
                ctx.check_hostname = False
                ctx.verify_mode = ssl.CERT_NONE
                resp_obj = urllib.request.urlopen(req, timeout=60, context=ctx)
            with resp_obj as resp:
                pkg_path.write_bytes(resp.read())
            subprocess.run(["ar", "x", str(pkg_path)], cwd=tmpdir, check=True, capture_output=True)
            for data_tar in tmpdir.glob("data.tar.*"):
                subprocess.run(["tar", "xf", str(data_tar)], cwd=tmpdir, check=True, capture_output=True)
                break
            for so_file in tmpdir.rglob("libstorm.so*"):
                if so_file.is_file() and not so_file.is_symlink():
                    shutil.copy2(so_file, lib_path)
                    return lib_path

    elif system == "windows" and machine in ("x86_64", "amd64"):
        lib_name = "storm.dll"
        url = f"{STORMLIB_RELEASE_URL}/stormlib_dll.zip"
        lib_path = LIB_DIR / lib_name

        print(f"Downloading StormLib {STORMLIB_VERSION}...")
        import zipfile
        with tempfile.TemporaryDirectory() as tmpdir:
            tmpdir = Path(tmpdir)
            pkg_path = tmpdir / "stormlib.zip"
            req = urllib.request.Request(url, headers={"User-Agent": "M2Editor/1.0"})
            with urllib.request.urlopen(req, timeout=60) as resp:
                pkg_path.write_bytes(resp.read())
            with zipfile.ZipFile(pkg_path) as zf:
                zf.extractall(tmpdir)
            for dll in tmpdir.rglob("storm.dll"):
                if "x64" in str(dll.parent).lower() or "64" in str(dll.parent):
                    shutil.copy2(dll, lib_path)
                    return lib_path
            for dll in tmpdir.rglob("storm.dll"):
                shutil.copy2(dll, lib_path)
                return lib_path

    raise ImportError(f"No prebuilt StormLib for {platform.system()} {platform.machine()}")


def _load_stormlib():
    """Find and load the StormLib shared library."""
    system = platform.system().lower()
    lib_name = "libstorm.so" if system == "linux" else "storm.dll"

    search_paths = [
        LIB_DIR / lib_name,
        Path("/usr/local/lib") / lib_name,
        Path("/usr/lib") / lib_name,
    ]

    for path in search_paths:
        if path.exists():
            try:
                return ctypes.CDLL(str(path))
            except OSError:
                continue

    lib_path = _download_stormlib()
    return ctypes.CDLL(str(lib_path))


_lib = _load_stormlib()

# Type aliases
HANDLE = c_void_p
DWORD = c_uint32
LCID = c_uint32
ULONGLONG = c_uint64
TCHAR = c_char_p

# MPQ constants
MPQ_CREATE_LISTFILE = 0x00100000
MPQ_CREATE_ATTRIBUTES = 0x00200000
MPQ_CREATE_ARCHIVE_V1 = 0x00000000

MPQ_FILE_COMPRESS = 0x00000200
MPQ_FILE_REPLACEEXISTING = 0x80000000

MPQ_COMPRESSION_ZLIB = 0x02
MPQ_OPEN_READ_ONLY = 0x00000100
SFILE_OPEN_FROM_MPQ = 0x00000000

# Function signatures
_lib.SFileCreateArchive.argtypes = [TCHAR, DWORD, DWORD, POINTER(HANDLE)]
_lib.SFileCreateArchive.restype = c_bool

_lib.SFileOpenArchive.argtypes = [TCHAR, DWORD, DWORD, POINTER(HANDLE)]
_lib.SFileOpenArchive.restype = c_bool

_lib.SFileCloseArchive.argtypes = [HANDLE]
_lib.SFileCloseArchive.restype = c_bool

_lib.SFileFlushArchive.argtypes = [HANDLE]
_lib.SFileFlushArchive.restype = c_bool

_lib.SFileAddFileEx.argtypes = [HANDLE, TCHAR, c_char_p, DWORD, DWORD, DWORD]
_lib.SFileAddFileEx.restype = c_bool

_lib.SFileCreateFile.argtypes = [HANDLE, c_char_p, ULONGLONG, DWORD, LCID, DWORD, POINTER(HANDLE)]
_lib.SFileCreateFile.restype = c_bool

_lib.SFileWriteFile.argtypes = [HANDLE, c_void_p, DWORD, DWORD]
_lib.SFileWriteFile.restype = c_bool

_lib.SFileFinishFile.argtypes = [HANDLE]
_lib.SFileFinishFile.restype = c_bool

_lib.SFileCloseFile.argtypes = [HANDLE]
_lib.SFileCloseFile.restype = c_bool

_lib.SFileHasFile.argtypes = [HANDLE, c_char_p]
_lib.SFileHasFile.restype = c_bool

_lib.SFileCompactArchive.argtypes = [HANDLE, TCHAR, c_bool]
_lib.SFileCompactArchive.restype = c_bool

_lib.SFileOpenFileEx.argtypes = [HANDLE, c_char_p, DWORD, POINTER(HANDLE)]
_lib.SFileOpenFileEx.restype = c_bool

_lib.SFileGetFileSize.argtypes = [HANDLE, POINTER(DWORD)]
_lib.SFileGetFileSize.restype = DWORD

_lib.SFileReadFile.argtypes = [HANDLE, c_void_p, DWORD, POINTER(DWORD), c_void_p]
_lib.SFileReadFile.restype = c_bool

_lib.SFileRemoveFile.argtypes = [HANDLE, c_char_p, DWORD]
_lib.SFileRemoveFile.restype = c_bool

class SFILE_FIND_DATA(ctypes.Structure):
    _fields_ = [
        ("cFileName", ctypes.c_char * 1024),
        ("szPlainName", ctypes.c_char_p),
        ("dwHashIndex", DWORD),
        ("dwBlockIndex", DWORD),
        ("dwFileSize", DWORD),
        ("dwFileFlags", DWORD),
        ("dwCompSize", DWORD),
        ("dwFileTimeLo", DWORD),
        ("dwFileTimeHi", DWORD),
        ("lcLocale", LCID),
    ]

_lib.SFileFindFirstFile.argtypes = [HANDLE, c_char_p, POINTER(SFILE_FIND_DATA), c_char_p]
_lib.SFileFindFirstFile.restype = HANDLE

_lib.SFileFindNextFile.argtypes = [HANDLE, POINTER(SFILE_FIND_DATA)]
_lib.SFileFindNextFile.restype = c_bool

_lib.SFileFindClose.argtypes = [HANDLE]
_lib.SFileFindClose.restype = c_bool


class StormLibError(Exception):
    pass


class MPQArchive:
    """Context manager for MPQ archive operations."""

    def __init__(self, path, mode='r', max_files=0):
        self.path = Path(path)
        self.mode = mode
        self.handle = HANDLE()
        self._closed = False

        path_bytes = str(self.path).encode('utf-8')

        if mode == 'r':
            if not _lib.SFileOpenArchive(path_bytes, 0, MPQ_OPEN_READ_ONLY, byref(self.handle)):
                raise StormLibError(f"Failed to open archive: {path}")
        elif mode == 'w':
            if max_files == 0:
                max_files = 4096
            flags = MPQ_CREATE_LISTFILE | MPQ_CREATE_ATTRIBUTES | MPQ_CREATE_ARCHIVE_V1
            if not _lib.SFileCreateArchive(path_bytes, flags, max_files, byref(self.handle)):
                raise StormLibError(f"Failed to create archive: {path}")
        elif mode == 'a':
            if not _lib.SFileOpenArchive(path_bytes, 0, 0, byref(self.handle)):
                raise StormLibError(f"Failed to open archive for writing: {path}")
        else:
            raise ValueError(f"Invalid mode: {mode}")

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()
        return False

    def close(self):
        if not self._closed and self.handle:
            _lib.SFileFlushArchive(self.handle)
            _lib.SFileCloseArchive(self.handle)
            self._closed = True

    def add_file(self, source_path, archive_name,
                 compression=MPQ_COMPRESSION_ZLIB,
                 flags=MPQ_FILE_COMPRESS | MPQ_FILE_REPLACEEXISTING):
        """Add a file from disk to the archive."""
        if self.mode == 'r':
            raise StormLibError("Archive opened in read-only mode")
        source_bytes = str(source_path).encode('utf-8')
        archive_bytes = archive_name.replace('/', '\\').encode('utf-8')
        if not _lib.SFileAddFileEx(self.handle, source_bytes, archive_bytes,
                                   flags, compression, compression):
            raise StormLibError(f"Failed to add file: {source_path} -> {archive_name}")

    def add_data(self, data, archive_name,
                 compression=MPQ_COMPRESSION_ZLIB,
                 flags=MPQ_FILE_COMPRESS | MPQ_FILE_REPLACEEXISTING):
        """Add raw bytes as a file in the archive."""
        if self.mode == 'r':
            raise StormLibError("Archive opened in read-only mode")
        archive_bytes = archive_name.replace('/', '\\').encode('utf-8')
        file_handle = HANDLE()
        if not _lib.SFileCreateFile(self.handle, archive_bytes, 0, len(data), 0,
                                    flags, byref(file_handle)):
            raise StormLibError(f"Failed to create file in archive: {archive_name}")
        try:
            if not _lib.SFileWriteFile(file_handle, data, len(data), compression):
                raise StormLibError(f"Failed to write file data: {archive_name}")
            if not _lib.SFileFinishFile(file_handle):
                raise StormLibError(f"Failed to finish file: {archive_name}")
        except:
            _lib.SFileCloseFile(file_handle)
            raise

    def has_file(self, archive_name):
        archive_bytes = archive_name.replace('/', '\\').encode('utf-8')
        return _lib.SFileHasFile(self.handle, archive_bytes)

    def read_file(self, archive_name):
        """Read a file from the archive."""
        archive_bytes = archive_name.replace('/', '\\').encode('utf-8')
        file_handle = HANDLE()
        if not _lib.SFileOpenFileEx(self.handle, archive_bytes, SFILE_OPEN_FROM_MPQ,
                                    byref(file_handle)):
            raise StormLibError(f"Failed to open file: {archive_name}")
        try:
            high_size = DWORD()
            size = _lib.SFileGetFileSize(file_handle, byref(high_size))
            if size == 0xFFFFFFFF:
                raise StormLibError(f"Failed to get file size: {archive_name}")
            buffer = ctypes.create_string_buffer(size)
            read_size = DWORD()
            if not _lib.SFileReadFile(file_handle, buffer, size, byref(read_size), None):
                raise StormLibError(f"Failed to read file: {archive_name}")
            return buffer.raw[:read_size.value]
        finally:
            _lib.SFileCloseFile(file_handle)

    def remove_file(self, archive_name):
        if self.mode == 'r':
            raise StormLibError("Archive opened in read-only mode")
        archive_bytes = archive_name.replace('/', '\\').encode('utf-8')
        if not _lib.SFileRemoveFile(self.handle, archive_bytes, 0):
            raise StormLibError(f"Failed to remove file: {archive_name}")

    def compact(self):
        if self.mode == 'r':
            raise StormLibError("Archive opened in read-only mode")
        if not _lib.SFileCompactArchive(self.handle, None, False):
            raise StormLibError("Failed to compact archive")

    def list_files(self, pattern="*"):
        """List all files in the archive matching a pattern."""
        files = []
        find_data = SFILE_FIND_DATA()
        find_handle = _lib.SFileFindFirstFile(self.handle, pattern.encode('utf-8'),
                                               byref(find_data), None)
        if not find_handle:
            return files
        try:
            while True:
                filename = find_data.cFileName.decode('utf-8', errors='replace')
                if filename and not filename.startswith('('):
                    files.append(filename)
                if not _lib.SFileFindNextFile(find_handle, byref(find_data)):
                    break
        finally:
            _lib.SFileFindClose(find_handle)
        return files
