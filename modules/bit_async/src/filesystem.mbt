///| Filesystem operations required by asynchronous repository operations.

///|
pub(all) enum PathKind {
  Missing
  File
  Directory
} derive(Eq, Debug)

///|
/// Asynchronous filesystem seam for repository operations.
///
/// `readdir` returns entry names rather than paths. `mkdir_p` succeeds when
/// the directory already exists.
pub(open) trait AsyncFileSystem {
  async fn kind(Self, String) -> PathKind
  async fn read_file(Self, String) -> Bytes
  async fn readdir(Self, String) -> Array[String]
  async fn mkdir_p(Self, String) -> Unit
  async fn write_file(Self, String, Bytes) -> Unit
  async fn remove_file(Self, String) -> Unit
  async fn remove_empty_dir(Self, String) -> Unit
}
