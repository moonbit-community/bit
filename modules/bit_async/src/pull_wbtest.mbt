///|
struct MemoryFs {
  inner : @io.TestFs
}

///|
fn MemoryFs::new() -> MemoryFs {
  { inner: @io.TestFs::new() }
}

///|
fn pull_test_concat(chunks : Array[Bytes]) -> Bytes {
  let result : Array[Byte] = []
  for chunk in chunks {
    for byte in chunk {
      result.push(byte)
    }
  }
  Bytes::from_array(FixedArray::makei(result.length(), i => result[i]))
}

///|
fn pull_test_v2_advertisement() -> Bytes {
  pull_test_concat([
    @protocol.pktline_encode("version 2\n"),
    @protocol.pktline_encode("ls-refs=unborn\n"),
    @protocol.pktline_encode("fetch=shallow wait-for-done\n"),
    @protocol.pktline_encode("object-format=sha1\n"),
    @protocol.pktline_flush(),
  ])
}

///|
fn pull_test_v2_refs(commit : @object.ObjectId) -> Bytes {
  pull_test_concat([
    @protocol.pktline_encode(
      "\{commit.to_hex()} HEAD symref-target:refs/heads/main\n",
    ),
    @protocol.pktline_encode("\{commit.to_hex()} refs/heads/main\n"),
    @protocol.pktline_flush(),
  ])
}

///|
fn pull_test_v2_pack(pack : Bytes) -> Bytes {
  let sideband : Array[Byte] = [b'\x01']
  for byte in pack {
    sideband.push(byte)
  }
  pull_test_concat([
    @protocol.pktline_encode("packfile\n"),
    @protocol.pktline_encode_bytes(
      Bytes::from_array(FixedArray::makei(sideband.length(), i => sideband[i])),
    ),
    @protocol.pktline_flush(),
  ])
}

///|
impl AsyncFileSystem for MemoryFs with fn kind(self, path) {
  if self.inner.is_file(path) {
    PathKind::File
  } else if self.inner.is_dir(path) {
    PathKind::Directory
  } else {
    PathKind::Missing
  }
}

///|
impl AsyncFileSystem for MemoryFs with fn read_file(self, path) {
  self.inner.read_file(path)
}

///|
impl AsyncFileSystem for MemoryFs with fn readdir(self, path) {
  self.inner.readdir(path)
}

///|
impl AsyncFileSystem for MemoryFs with fn mkdir_p(self, path) {
  self.inner.mkdir_p(path)
}

///|
impl AsyncFileSystem for MemoryFs with fn write_file(self, path, content) {
  self.inner.write_file(path, content)
}

///|
impl AsyncFileSystem for MemoryFs with fn remove_file(self, path) {
  self.inner.remove_file(path)
}

///|
impl AsyncFileSystem for MemoryFs with fn remove_empty_dir(self, path) {
  self.inner.remove_dir(path)
}

///|
async test "async pull preserves untracked and unchanged modified files" {
  let fs = MemoryFs::new()
  fs.inner.mkdir_p("/repo")
  fs.inner.write_string("/repo/changed", "old")
  fs.inner.write_string("/repo/deleted", "gone")
  fs.inner.write_string("/repo/unchanged", "locally modified")
  fs.inner.write_string("/repo/untracked", "keep")
  let before = {
    "changed": b"old",
    "deleted": b"gone",
    "unchanged": b"upstream",
  }
  let after = { "changed": b"new", "added": b"hello", "unchanged": b"upstream" }
  apply_worktree_changes(fs, "/repo", before, after)
  @test.assert_eq(fs.inner.read_file("/repo/changed"), b"new")
  @test.assert_eq(fs.inner.read_file("/repo/added"), b"hello")
  @test.assert_eq(fs.inner.read_file("/repo/unchanged"), b"locally modified")
  @test.assert_eq(fs.inner.read_file("/repo/untracked"), b"keep")
}

///|
async test "async pull rejects conflicting local changes" {
  let fs = MemoryFs::new()
  fs.inner.mkdir_p("/repo")
  fs.inner.write_string("/repo/changed", "local")
  try
    apply_worktree_changes(fs, "/repo", { "changed": b"old" }, {
      "changed": b"new",
    })
  catch {
    @object.GitError::IoError(message) =>
      @test.assert_eq(
        message, "local change would be overwritten by pull: changed",
      )
    error => fail("unexpected error: \{error}")
  } noraise {
    _ => fail("expected conflicting local change")
  }
}

///|
async test "async pull fetches and applies a fast-forward" {
  let old_blob = b"old\n"
  let old_blob_id = @object.hash_object_content(Blob, old_blob)
  let old_tree = @object.serialize_tree([
    @object.TreeEntry::new("100644", "value.txt", old_blob_id),
  ])
  let old_tree_id = @object.hash_object_content(Tree, old_tree)
  let old_commit = @object.serialize_commit_content(
    @object.Commit::new(
      old_tree_id,
      [],
      "Test <test@example.com>",
      1000L,
      "+0000",
      "Test <test@example.com>",
      1000L,
      "+0000",
      "old\n",
    ),
  )
  let old_commit_id = @object.hash_object_content(Commit, old_commit)
  let old_objects = [
    @object.PackObject::new(Blob, old_blob),
    @object.PackObject::new(Tree, old_tree),
    @object.PackObject::new(Commit, old_commit),
  ]
  let fs = MemoryFs::new()
  let old_store = @repo.ObjectStore::from_pack(old_objects)
  @repo.materialize_clone_to_fs(
    old_store,
    old_commit_id,
    "refs/heads/main",
    "https://example.com/repo.git",
    fs.inner,
    "/repo",
  )
  let old_pack = @pack.create_packfile(old_objects)
  @pack.write_packfile_with_index(fs.inner, "/repo/.git", old_pack, old_objects)
  fs.inner.write_string("/repo/.git/shallow", "\{old_commit_id.to_hex()}\n")

  let new_blob = b"new\n"
  let new_blob_id = @object.hash_object_content(Blob, new_blob)
  let new_tree = @object.serialize_tree([
    @object.TreeEntry::new("100644", "value.txt", new_blob_id),
  ])
  let new_tree_id = @object.hash_object_content(Tree, new_tree)
  let new_commit = @object.serialize_commit_content(
    @object.Commit::new(
      new_tree_id,
      [old_commit_id],
      "Test <test@example.com>",
      2000L,
      "+0000",
      "Test <test@example.com>",
      2000L,
      "+0000",
      "new\n",
    ),
  )
  let new_commit_id = @object.hash_object_content(Commit, new_commit)
  let new_objects = [
    @object.PackObject::new(Blob, new_blob),
    @object.PackObject::new(Tree, new_tree),
    @object.PackObject::new(Commit, new_commit),
  ]
  let refs = pull_test_v2_refs(new_commit_id)
  let fetch = pull_test_v2_pack(@pack.create_packfile(new_objects))
  let mut fetch_request = ""
  let result = pull_main_http(
    fs,
    "/repo",
    "https://example.com/repo.git",
    async fn(
      _url : String,
      _headers : Map[String, String],
    ) -> (@types.HttpResponse, Bytes) raise @object.GitError {
      @async.sleep(0) catch {
        error => raise @object.GitError::IoError(error.to_string())
      }
      (@types.HttpResponse::new(200), pull_test_v2_advertisement())
    },
    async fn(
      _url : String,
      body : Bytes,
      _headers : Map[String, String],
    ) -> (@types.HttpResponse, Bytes) raise @object.GitError {
      @async.sleep(0) catch {
        error => raise @object.GitError::IoError(error.to_string())
      }
      let response = if @utf8.decode_lossy(body[:]).contains("command=ls-refs") {
        refs
      } else {
        fetch_request = @utf8.decode_lossy(body[:])
        fetch
      }
      (@types.HttpResponse::new(200), response)
    },
  )
  @test.assert_eq(
    result,
    PullResult::Updated(from=old_commit_id, to=new_commit_id),
  )
  @test.assert_eq(fs.inner.read_file("/repo/value.txt"), new_blob)
  @test.assert_eq(
    fs.inner.read_string("/repo/.git/refs/heads/main"),
    "\{new_commit_id.to_hex()}\n",
  )
  @test.assert_eq(
    fs.inner.read_string("/repo/.git/refs/remotes/origin/main"),
    "\{new_commit_id.to_hex()}\n",
  )
  assert_true(fetch_request.contains("shallow \{old_commit_id.to_hex()}\n"))
  assert_true(fetch_request.contains("have \{old_commit_id.to_hex()}\n"))
}
