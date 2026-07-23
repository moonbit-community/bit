///| Filesystem operations required by asynchronous repository updates.

///|
pub(all) enum PathKind {
  Missing
  File
  Directory
} derive(Eq, Debug)

///|
/// Asynchronous filesystem seam for repository operations.
///
/// Implementations must treat paths as UTF-8 host paths and return directory
/// entry names rather than paths from `readdir`.
pub(open) trait AsyncFileSystem {
  async fn kind(Self, String) -> PathKind
  async fn read_file(Self, String) -> Bytes
  async fn readdir(Self, String) -> Array[String]
  async fn mkdir_p(Self, String) -> Unit
  async fn write_file(Self, String, Bytes) -> Unit
  async fn remove_file(Self, String) -> Unit
  async fn remove_empty_dir(Self, String) -> Unit
}
