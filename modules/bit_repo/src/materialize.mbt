///| Git repository materialization (.git + index)

///|
pub fn materialize_clone_to_fs(
  store : ObjectStore,
  commit_id : @object.ObjectId,
  refname : String,
  remote_url : String,
  fs : &@types.FileSystem,
  root : String,
  rfs : &@types.RepoFileSystem,
) -> Unit raise @object.GitError {
  checkout_commit_to_fs(store, commit_id, fs, root, rfs)
  write_git_metadata(store, commit_id, refname, remote_url, fs, root)
}

///|
pub fn write_git_metadata(
  store : ObjectStore,
  commit_id : @object.ObjectId,
  refname : String,
  remote_url : String,
  fs : &@types.FileSystem,
  root : String,
) -> Unit raise @object.GitError {
  let git_dir = join_path(root, ".git")
  fs.mkdir_p(git_dir)
  fs.mkdir_p(join_path(git_dir, "objects"))
  fs.mkdir_p(join_path(git_dir, "objects/info"))
  fs.mkdir_p(join_path(git_dir, "objects/pack"))
  fs.mkdir_p(join_path(git_dir, "refs/heads"))
  fs.mkdir_p(join_path(git_dir, "refs/tags"))
  // Note: loose objects are not written here - pack file is used instead
  write_head_and_refs(fs, git_dir, refname, commit_id)
  write_config(fs, git_dir, remote_url)
  write_packed_refs(fs, git_dir)
  write_alternates(fs, git_dir)
  write_index_v2(store, fs, git_dir, commit_id, root)
}

///|
fn write_head_and_refs(
  fs : &@types.FileSystem,
  git_dir : String,
  refname : String,
  commit_id : @object.ObjectId,
) -> Unit raise @object.GitError {
  let head_path = join_path(git_dir, "HEAD")
  if refname == "HEAD" {
    write_text(fs, head_path, commit_id.to_hex() + "\n")
    return
  }
  write_text(fs, head_path, "ref: \{refname}\n")
  let ref_path = join_path(git_dir, refname)
  let dir = parent_dir(ref_path)
  fs.mkdir_p(dir)
  write_text(fs, ref_path, commit_id.to_hex() + "\n")
}

///|
fn write_config(
  fs : &@types.FileSystem,
  git_dir : String,
  remote_url : String,
) -> Unit raise @object.GitError {
  let config_path = join_path(git_dir, "config")
  let base =
    #|[core]
    #|	repositoryformatversion = 0
    #|	filemode = true
    #|	bare = false
    #|	logallrefupdates = true
  let remote_block =
    $|[remote "origin"]
    $|	url = \{remote_url}
    $|	fetch = +refs/heads/*:refs/remotes/origin/*
    $|
  let config = if remote_url.length() == 0 {
    base + "\n"
  } else {
    base + "\n" + remote_block
  }
  write_text(fs, config_path, config)
}

///|
fn write_packed_refs(
  fs : &@types.FileSystem,
  git_dir : String,
) -> Unit raise @object.GitError {
  let path = join_path(git_dir, "packed-refs")
  write_text(fs, path, "# pack-refs with: peeled fully-peeled\n")
}

///|
fn write_alternates(
  fs : &@types.FileSystem,
  git_dir : String,
) -> Unit raise @object.GitError {
  let path = join_path(git_dir, "objects/info/alternates")
  write_text(fs, path, "")
}

///|
fn write_index_v2(
  store : ObjectStore,
  fs : &@types.FileSystem,
  git_dir : String,
  commit_id : @object.ObjectId,
  root : String,
) -> Unit raise @object.GitError {
  let entries = collect_commit_entries(store, commit_id)
  // Git index entries must be in lexical path order.
  entries.sort_by((a, b) => String::lexical_compare(a.path, b.path))
  let mtimes : Map[String, (Int, Int)] = Map([])
  for entry in entries {
    let full_path = join_path(root, entry.path)
    mtimes[entry.path] = match @io.lstat_entry_meta(full_path) {
      Some(meta) => meta.mtime()
      None => (0, 0)
    }
  }
  fs.write_file(join_path(git_dir, "index"), encode_index_v2(entries, mtimes))
}

///|
/// Build a Git index v2 snapshot for `commit_id`.
///
/// Stat fields are zeroed because callers may materialize the index through a
/// filesystem abstraction that does not expose host metadata.
pub fn build_index_v2(
  store : ObjectStore,
  commit_id : @object.ObjectId,
) -> Bytes raise @object.GitError {
  let entries = collect_commit_entries(store, commit_id)
  entries.sort_by((a, b) => String::lexical_compare(a.path, b.path))
  encode_index_v2(entries, Map([]))
}

///|
fn encode_index_v2(
  entries : Array[IndexEntryInfo],
  mtimes : Map[String, (Int, Int)],
) -> Bytes {
  let out : Array[Byte] = []
  // Header: "DIRC" + version(2) + count
  out.push(b'D')
  out.push(b'I')
  out.push(b'R')
  out.push(b'C')
  push_u32_be(out, 2)
  push_u32_be(out, entries.length())
  for e in entries {
    let (mtime_sec, mtime_nsec) = mtimes.get(e.path).unwrap_or((0, 0))
    // Git index v2 entry format (62 bytes fixed + variable name):
    // ctime_sec (4) + ctime_nsec (4)
    push_u32_be(out, mtime_sec)
    push_u32_be(out, mtime_nsec)
    // mtime_sec (4) + mtime_nsec (4)
    push_u32_be(out, mtime_sec)
    push_u32_be(out, mtime_nsec)
    // dev (4) + ino (4)
    push_u32_be(out, 0)
    push_u32_be(out, 0)
    // mode (4) - comes BEFORE uid/gid
    push_u32_be(out, e.mode)
    // uid (4) + gid (4)
    push_u32_be(out, 0)
    push_u32_be(out, 0)
    // file_size (4)
    push_u32_be(out, e.size)
    // object id
    for b in e.id.bytes {
      out.push(b)
    }
    // Convert path to UTF-8 bytes
    let path_bytes = @utf8.encode(e.path)
    let name_byte_len = path_bytes.length()
    let name_len = if name_byte_len < 0x0fff { name_byte_len } else { 0x0fff }
    push_u16_be(out, name_len)
    for i in 0..<path_bytes.length() {
      out.push(path_bytes[i])
    }
    out.push(b'\x00')
    // Pad to 8-byte alignment from entry start
    // Entry fixed part = 62 bytes, then name bytes + NUL + padding
    // Total entry size must be multiple of 8
    let entry_len = 62 + name_byte_len + 1 // fixed + name bytes + NUL
    let padded_len = (entry_len + 7) & (0xFFFFFFFF - 7) // round up to 8
    let padding = padded_len - entry_len
    for _i in 0..<padding {
      out.push(b'\x00')
    }
  }
  let content = Bytes::from_array(FixedArray::makei(out.length(), i => out[i]))
  let checksum = @object.sha1(content)
  for b in checksum.bytes {
    out.push(b)
  }
  let index_bytes = Bytes::from_array(
    FixedArray::makei(out.length(), i => out[i]),
  )
  index_bytes
}

///|
/// Return whether an index snapshot represents exactly `commit_id`.
///
/// Stat data and optional index extensions are ignored. Conflict stages,
/// paths, object IDs, and file modes are compared.
pub fn index_matches_commit(
  store : ObjectStore,
  commit_id : @object.ObjectId,
  index : Bytes,
) -> Bool raise @object.GitError {
  let expected = collect_commit_entries(store, commit_id)
  expected.sort_by((a, b) => String::lexical_compare(a.path, b.path))
  let actual = parse_index_snapshot(index, commit_id.hash_size())
  actual.sort_by((a, b) => String::lexical_compare(a.path, b.path))
  if actual.length() != expected.length() {
    return false
  }
  for i in 0..<expected.length() {
    let left = expected[i]
    let right = actual[i]
    if (right.flags & 0xf000) != 0 ||
      right.extended_flags != 0 ||
      left.path != right.path ||
      left.id != right.id ||
      left.mode != right.mode {
      return false
    }
  }
  true
}

///|
priv struct IndexEntryInfo {
  path : String
  id : @object.ObjectId
  size : Int
  mode : Int
}

///|
priv struct IndexSnapshotEntry {
  path : String
  id : @object.ObjectId
  mode : Int
  flags : Int
  extended_flags : Int
}

///|
fn parse_index_snapshot(
  index : Bytes,
  hash_size : Int,
) -> Array[IndexSnapshotEntry] raise @object.GitError {
  if index.length() < 12 + hash_size ||
    index[0] != b'D' ||
    index[1] != b'I' ||
    index[2] != b'R' ||
    index[3] != b'C' {
    raise @object.GitError::InvalidObject("Invalid index header")
  }
  let version = read_u32_be(index, 4)
  if version != 2 && version != 3 {
    raise @object.GitError::InvalidObject(
      "Unsupported index version: \{version}",
    )
  }
  let count = read_u32_be(index, 8)
  let entries : Array[IndexSnapshotEntry] = Array::new(capacity=count)
  let mut offset = 12
  for _ in 0..<count {
    let entry_start = offset
    if offset + 40 + hash_size + 2 > index.length() - hash_size {
      raise @object.GitError::InvalidObject("Index entry truncated")
    }
    let mode = read_u32_be(index, offset + 24)
    let id = @object.ObjectId::from_bytes_at(index, offset + 40, hash_size~)
    offset += 40 + hash_size
    let flags = read_u16_be(index, offset)
    offset += 2
    let extended_flags = if (flags & 0x4000) != 0 {
      if offset + 2 > index.length() - hash_size {
        raise @object.GitError::InvalidObject("Index entry truncated")
      }
      let value = read_u16_be(index, offset)
      offset += 2
      value
    } else {
      0
    }
    let path_start = offset
    while offset < index.length() - hash_size && index[offset] != b'\x00' {
      offset += 1
    }
    if offset >= index.length() - hash_size {
      raise @object.GitError::InvalidObject("Index path is not terminated")
    }
    let path = @utf8.decode_lossy(index[path_start:offset])
    offset += 1
    while (offset - entry_start) % 8 != 0 {
      offset += 1
    }
    entries.push({ path, id, mode, flags, extended_flags })
  }
  entries
}

///|
fn collect_commit_entries(
  store : ObjectStore,
  commit_id : @object.ObjectId,
) -> Array[IndexEntryInfo] raise @object.GitError {
  let commit_obj = store.get(commit_id)
  match commit_obj {
    None => raise @object.GitError::InvalidObject("Missing commit object")
    Some(obj) => {
      if obj.obj_type != @object.ObjectType::Commit {
        raise @object.GitError::InvalidObject("Object is not a commit")
      }
      let info = parse_commit(obj.data)
      let out : Array[IndexEntryInfo] = []
      collect_tree_entries(store, info.tree, "", out)
      out
    }
  }
}

///|
fn collect_tree_entries(
  store : ObjectStore,
  tree_id : @object.ObjectId,
  prefix : String,
  out : Array[IndexEntryInfo],
) -> Unit raise @object.GitError {
  let tree_obj = store.get(tree_id)
  match tree_obj {
    None => raise @object.GitError::InvalidObject("Missing tree object")
    Some(obj) => {
      if obj.obj_type != @object.ObjectType::Tree {
        raise @object.GitError::InvalidObject("Object is not a tree")
      }
      let entries = parse_tree(obj.data)
      for entry in entries {
        verify_tree_entry_name(entry.name)
        let path = if prefix.length() == 0 {
          entry.name
        } else {
          prefix + "/" + entry.name
        }
        if is_tree_mode(entry.mode) {
          collect_tree_entries(store, entry.id, path, out)
        } else if is_gitlink_mode(entry.mode) {
          let mode = parse_octal(entry.mode)
          out.push({ path, id: entry.id, size: 0, mode })
        } else {
          let blob = store.get(entry.id)
          match blob {
            None => raise @object.GitError::InvalidObject("Missing blob object")
            Some(b) => {
              if b.obj_type != @object.ObjectType::Blob {
                raise @object.GitError::InvalidObject("Object is not a blob")
              }
              let mode = parse_octal(entry.mode)
              out.push({ path, id: entry.id, size: b.data.length(), mode })
            }
          }
        }
      }
    }
  }
}

///|
fn parse_octal(s : String) -> Int {
  let mut result = 0
  for c in s {
    if c < '0' || c > '7' {
      continue
    }
    result = result * 8 + (c.to_int() - '0'.to_int())
  }
  result
}

///|
fn push_u32_be(out : Array[Byte], v : Int) -> Unit {
  out.push(((v >> 24) & 0xff).to_byte())
  out.push(((v >> 16) & 0xff).to_byte())
  out.push(((v >> 8) & 0xff).to_byte())
  out.push((v & 0xff).to_byte())
}

///|
fn push_u16_be(out : Array[Byte], v : Int) -> Unit {
  out.push(((v >> 8) & 0xff).to_byte())
  out.push((v & 0xff).to_byte())
}

///|
fn read_u32_be(data : Bytes, offset : Int) -> Int {
  (data[offset].to_int() << 24) |
  (data[offset + 1].to_int() << 16) |
  (data[offset + 2].to_int() << 8) |
  data[offset + 3].to_int()
}

///|
fn read_u16_be(data : Bytes, offset : Int) -> Int {
  (data[offset].to_int() << 8) | data[offset + 1].to_int()
}

///|
fn write_text(
  fs : &@types.FileSystem,
  path : String,
  content : String,
) -> Unit raise @object.GitError {
  fs.write_string(path, content)
}

///|
