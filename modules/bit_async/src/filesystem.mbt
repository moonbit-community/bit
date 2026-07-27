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
/// the directory already exists. Path interpretation and capability scoping
/// belong to the implementation.
pub(open) trait AsyncFileSystem {
  async fn kind(Self, String) -> PathKind raise @object.GitError
  async fn read_file(Self, String) -> Bytes raise @object.GitError
  async fn readdir(Self, String) -> Array[String] raise @object.GitError
  async fn mkdir_p(Self, String) -> Unit raise @object.GitError
  async fn write_file(Self, String, Bytes) -> Unit raise @object.GitError
  async fn remove_file(Self, String) -> Unit raise @object.GitError
  async fn remove_empty_dir(Self, String) -> Unit raise @object.GitError
}
