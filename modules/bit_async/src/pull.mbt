///| Fast-forward pull over asynchronous HTTP and filesystem adapters.

///|
pub(all) enum PullResult {
  Unchanged(@object.ObjectId)
  Updated(from~ : @object.ObjectId, to~ : @object.ObjectId)
} derive(Eq, Debug)

///|
async fn read_ref(
  fs : &AsyncFileSystem,
  git_dir : String,
  refname : String,
) -> @object.ObjectId? {
  let loose_path = @bit.join_path(git_dir, refname)
  if fs.kind(loose_path) == File {
    let value = fs.read_file(loose_path)
    return Some(
      @object.ObjectId::from_hex(@utf8.decode_lossy(value[:]).trim().to_owned()),
    ) catch {
      _ => None
    }
  }
  let packed_path = @bit.join_path(git_dir, "packed-refs")
  if fs.kind(packed_path) == File {
    let text = @utf8.decode_lossy(fs.read_file(packed_path)[:])
    for entry in @refs.parse_packed_refs_text(text) {
      if entry.refname == refname {
        return Some(@object.ObjectId::from_hex(entry.oid)) catch { _ => None }
      }
    }
  }
  None
}

///|
async fn read_shallow_boundaries(
  fs : &AsyncFileSystem,
  git_dir : String,
) -> Array[@object.ObjectId] {
  let path = @bit.join_path(git_dir, "shallow")
  if fs.kind(path) != File {
    return []
  }
  let result : Array[@object.ObjectId] = []
  for line in @utf8.decode_lossy(fs.read_file(path)[:]).split("\n") {
    let value = line.trim().to_owned()
    if value.length() != 40 {
      continue
    }
    let id = @object.ObjectId::from_hex(value) catch { _ => continue }
    result.push(id)
  }
  result
}

///|
async fn missing_parent_directories(
  fs : &AsyncFileSystem,
  stop : String,
  paths : Array[String],
) -> Array[String] {
  let missing : Map[String, Bool] = Map([])
  for path in paths {
    let mut directory = @repo.parent_dir(path)
    for ;; {
      if directory == stop {
        break
      }
      if fs.kind(directory) == Missing {
        missing[directory] = true
      }
      let parent = @repo.parent_dir(directory)
      if parent == directory {
        break
      }
      directory = parent
    }
  }
  let result = [ for directory, _ in missing => directory ]
  result.sort_by(fn(a, b) {
    let depth = b.length().compare(a.length())
    if depth == 0 {
      String::compare(a, b)
    } else {
      depth
    }
  })
  result
}

///|
async fn remove_created_directories(
  fs : &AsyncFileSystem,
  directories : Array[String],
) -> Unit {
  for directory in directories {
    match fs.kind(directory) {
      Directory => fs.remove_empty_dir(directory)
      Missing => ()
      File =>
        raise @object.GitError::IoError(
          "path created as a directory became a file during pull: \{directory}",
        )
    }
  }
}

///|
async fn load_pack_objects(
  fs : &AsyncFileSystem,
  git_dir : String,
) -> Array[@object.PackObject] {
  let pack_dir = @bit.join_path(git_dir, "objects/pack")
  if fs.kind(pack_dir) != Directory {
    return []
  }
  let pending : Array[Bytes] = []
  for name in fs.readdir(pack_dir) {
    if name.has_suffix(".pack") {
      pending.push(fs.read_file(@bit.join_path(pack_dir, name)))
    }
  }
  let objects : Array[@object.PackObject] = []
  let mut remaining = pending
  for ;; {
    if remaining.length() == 0 {
      break
    }
    let deferred : Array[Bytes] = []
    let mut made_progress = false
    for pack in remaining {
      try @pack.parse_packfile_with_bases(pack, objects) catch {
        _ => deferred.push(pack)
      } noraise {
        parsed => {
          objects.append(parsed)
          made_progress = true
        }
      }
    }
    if !made_progress {
      raise @object.GitError::PackfileError(
        "local packfiles have unresolved delta bases",
      )
    }
    remaining = deferred
  }
  objects
}

///|
async fn load_loose_objects(
  fs : &AsyncFileSystem,
  git_dir : String,
) -> Array[@object.PackObject] {
  let objects_dir = @bit.join_path(git_dir, "objects")
  if fs.kind(objects_dir) != Directory {
    return []
  }
  let objects : Array[@object.PackObject] = []
  for prefix in fs.readdir(objects_dir) {
    if prefix.length() != 2 {
      continue
    }
    let directory = @bit.join_path(objects_dir, prefix)
    if fs.kind(directory) != Directory {
      continue
    }
    for suffix in fs.readdir(directory) {
      if suffix.length() != 38 {
        continue
      }
      let path = @bit.join_path(directory, suffix)
      if fs.kind(path) != File {
        continue
      }
      let object = @object.decode_loose_object(fs.read_file(path))
      let expected = prefix + suffix
      if object.id.to_hex() != expected {
        raise @object.GitError::HashMismatch(expected, object.id.to_hex())
      }
      objects.push(object)
    }
  }
  objects
}

///|
fn commit_is_ancestor(
  store : @repo.ObjectStore,
  ancestor : @object.ObjectId,
  descendant : @object.ObjectId,
) -> Bool {
  let pending = [descendant]
  let seen : Map[String, Bool] = Map([])
  for cursor = 0; cursor < pending.length(); {
    let current = pending[cursor]
    if current == ancestor {
      return true
    }
    let key = current.to_hex()
    if !seen.contains(key) {
      seen[key] = true
      match store.get(current) {
        Some(object) if object.obj_type == Commit => {
          let commit = @repo.parse_commit(object.data) catch {
            _ => return false
          }
          pending.append(commit.parents)
        }
        _ => ()
      }
    }
    continue cursor + 1
  }
  false
}

///|
fn changed_worktree_paths(
  before : Map[String, Bytes],
  after : Map[String, Bytes],
) -> Array[String] {
  let paths : Map[String, Bool] = Map([])
  for path, _ in before {
    paths[path] = true
  }
  for path, _ in after {
    paths[path] = true
  }
  let changed : Array[String] = []
  for path, _ in paths {
    if before.get(path) != after.get(path) {
      changed.push(path)
    }
  }
  changed.sort()
  changed
}

///|
async fn verify_worktree_changes(
  fs : &AsyncFileSystem,
  root : String,
  before : Map[String, Bytes],
  changed : Array[String],
) -> Unit {
  for path in changed {
    let full_path = @bit.join_path(root, path)
    match (before.get(path), fs.kind(full_path)) {
      (None, Missing) => ()
      (None, Directory) => {
        let prefix = path + "/"
        let mut tracked_directory = false
        for old_path, _ in before {
          if old_path.has_prefix(prefix) {
            tracked_directory = true
            break
          }
        }
        if !tracked_directory {
          raise @object.GitError::IoError(
            "untracked path would be overwritten by pull: \{path}",
          )
        }
      }
      (Some(_), Missing) =>
        raise @object.GitError::IoError(
          "local change would be overwritten by pull: \{path}",
        )
      (Some(expected), File) =>
        if fs.read_file(full_path) != expected {
          raise @object.GitError::IoError(
            "local change would be overwritten by pull: \{path}",
          )
        }
      (_, _) =>
        raise @object.GitError::IoError(
          "untracked path would be overwritten by pull: \{path}",
        )
    }
  }
}

///|
async fn apply_worktree_changes(
  fs : &AsyncFileSystem,
  root : String,
  before : Map[String, Bytes],
  after : Map[String, Bytes],
) -> Array[String] {
  let changed = changed_worktree_paths(before, after)
  verify_worktree_changes(fs, root, before, changed)
  let added_paths : Array[String] = []
  for path in changed {
    if after.get(path) is Some(_) {
      added_paths.push(@bit.join_path(root, path))
    }
  }
  let created_directories = missing_parent_directories(fs, root, added_paths)
  try {
    // Remove deleted paths first so file/directory transitions do not depend
    // on lexicographic path order.
    for path in changed {
      if after.get(path) is None {
        let full_path = @bit.join_path(root, path)
        if fs.kind(full_path) == File {
          fs.remove_file(full_path)
        }
      }
    }
    for path in changed {
      guard after.get(path) is Some(content) else { continue }
      let full_path = @bit.join_path(root, path)
      if fs.kind(full_path) == Directory {
        fs.remove_empty_dir(full_path)
      }
      fs.mkdir_p(@repo.parent_dir(full_path))
      fs.write_file(full_path, content)
    }
  } catch {
    error =>
      try
        restore_worktree_changes(fs, root, before, changed, created_directories)
      catch {
        rollback_error =>
          raise @object.GitError::IoError(
            "pull failed: \{error}; restoring the worktree also failed: \{rollback_error}",
          )
      } noraise {
        _ => raise error
      }
  } noraise {
    _ => ()
  }
  created_directories
}

///|
async fn restore_worktree_changes(
  fs : &AsyncFileSystem,
  root : String,
  before : Map[String, Bytes],
  changed : Array[String],
  created_directories : Array[String],
) -> Unit {
  // Remove paths introduced by the new tree before restoring paths from the
  // old tree. This also handles file/directory transitions.
  for path in changed {
    let full_path = @bit.join_path(root, path)
    if before.get(path) is None {
      match fs.kind(full_path) {
        File => fs.remove_file(full_path)
        Directory => fs.remove_empty_dir(full_path)
        Missing => ()
      }
    }
  }
  remove_created_directories(fs, created_directories)
  for path in changed {
    guard before.get(path) is Some(content) else { continue }
    let full_path = @bit.join_path(root, path)
    if fs.kind(full_path) == Directory {
      fs.remove_empty_dir(full_path)
    }
    fs.mkdir_p(@repo.parent_dir(full_path))
    fs.write_file(full_path, content)
  }
}

///|
fn pack_id(pack : Bytes) -> @object.ObjectId raise @object.GitError {
  if pack.length() < 20 {
    raise PackfileError("Packfile too short")
  }
  let start = pack.length() - 20
  @object.ObjectId::new(FixedArray::makei(20, i => pack[start + i]))
}

///|
async fn write_repository_state(
  fs : &AsyncFileSystem,
  root : String,
  store : @repo.ObjectStore,
  commit : @object.ObjectId,
  objects : Array[@object.PackObject],
  shallow_boundaries : Array[@object.ObjectId],
) -> Unit {
  let git_dir = @bit.join_path(root, ".git")
  let canonical_pack = @pack.create_packfile(objects)
  let id = pack_id(canonical_pack)
  let pack_dir = @bit.join_path(git_dir, "objects/pack")
  let base = "pack-\{id.to_hex()}"
  let pack_path = @bit.join_path(pack_dir, base + ".pack")
  let pack_index_path = @bit.join_path(pack_dir, base + ".idx")
  let index_path = @bit.join_path(git_dir, "index")
  let shallow_path = @bit.join_path(git_dir, "shallow")
  let remote_ref = @bit.join_path(git_dir, "refs/remotes/origin/main")
  let local_ref = @bit.join_path(git_dir, "refs/heads/main")
  let pack_existed = fs.kind(pack_path) == File
  let pack_index_existed = fs.kind(pack_index_path) == File
  let previous_index = if fs.kind(index_path) == File {
    Some(fs.read_file(index_path))
  } else {
    None
  }
  let previous_remote_ref = if fs.kind(remote_ref) == File {
    Some(fs.read_file(remote_ref))
  } else {
    None
  }
  let previous_shallow = if fs.kind(shallow_path) == File {
    Some(fs.read_file(shallow_path))
  } else {
    None
  }
  let previous_local_ref = if fs.kind(local_ref) == File {
    Some(fs.read_file(local_ref))
  } else {
    None
  }
  let created_directories = missing_parent_directories(fs, git_dir, [
    pack_path, remote_ref, local_ref,
  ])
  try {
    fs.mkdir_p(pack_dir)
    if !pack_existed {
      fs.write_file(pack_path, canonical_pack)
    }
    if !pack_index_existed {
      fs.write_file(pack_index_path, @pack.build_pack_index(canonical_pack))
    }
    fs.write_file(index_path, @repo.build_index_v2(store, commit))
    if shallow_boundaries.length() == 0 {
      if fs.kind(shallow_path) == File {
        fs.remove_file(shallow_path)
      }
    } else {
      fs.write_file(
        shallow_path,
        @utf8.encode(
          [ for id in shallow_boundaries => id.to_hex() ].join("\n") + "\n",
        ),
      )
    }
    fs.mkdir_p(@repo.parent_dir(remote_ref))
    fs.write_file(remote_ref, @utf8.encode("\{commit.to_hex()}\n"))
    fs.mkdir_p(@repo.parent_dir(local_ref))
    // Update the checked-out ref last so interrupted pulls remain detectable.
    fs.write_file(local_ref, @utf8.encode("\{commit.to_hex()}\n"))
  } catch {
    error =>
      try {
        restore_file(fs, index_path, previous_index)
        restore_file(fs, remote_ref, previous_remote_ref)
        restore_file(fs, shallow_path, previous_shallow)
        if !pack_existed && fs.kind(pack_path) == File {
          fs.remove_file(pack_path)
        }
        if !pack_index_existed && fs.kind(pack_index_path) == File {
          fs.remove_file(pack_index_path)
        }
        // Restore the checked-out ref last.
        restore_file(fs, local_ref, previous_local_ref)
        remove_created_directories(fs, created_directories)
      } catch {
        rollback_error =>
          raise @object.GitError::IoError(
            "pull failed: \{error}; restoring repository state also failed: \{rollback_error}",
          )
      } noraise {
        _ => raise error
      }
  } noraise {
    _ => ()
  }
}

///|
async fn restore_file(
  fs : &AsyncFileSystem,
  path : String,
  previous : Bytes?,
) -> Unit {
  match previous {
    None => if fs.kind(path) == File { fs.remove_file(path) }
    Some(content) => {
      if fs.kind(path) == Directory {
        fs.remove_empty_dir(path)
      }
      fs.mkdir_p(@repo.parent_dir(path))
      fs.write_file(path, content)
    }
  }
}

///|
/// Fast-forward the `main` branch of an existing repository using asynchronous
/// HTTP and filesystem adapters. The server may return a thin pack because the
/// current commit is advertised as a `have`; received objects are stored in a
/// self-contained local pack.
pub async fn pull_main_http(
  fs : &AsyncFileSystem,
  http : &AsyncHttpClient,
  root : String,
  remote : String,
) -> PullResult {
  let http_get = async fn(
    url : String,
    headers : Map[String, String],
  ) -> (@types.HttpResponse, Bytes) raise @object.GitError {
    http.get(url, headers)
  }
  let http_post = async fn(
    url : String,
    body : Bytes,
    headers : Map[String, String],
  ) -> (@types.HttpResponse, Bytes) raise @object.GitError {
    http.post(url, body, headers)
  }
  let git_dir = @bit.join_path(root, ".git")
  guard read_ref(fs, git_dir, "refs/heads/main") is Some(current) else {
    raise @object.GitError::IoError(
      "async pull requires an existing refs/heads/main checkout",
    )
  }
  let (refs, capabilities, version, symrefs) = @protocol.discover_upload_refs_with_http(
    remote, true, http_get, http_post,
  )
  guard @protocol.select_default_ref(refs, symrefs) is Some((refname, target)) else {
    raise @object.GitError::ProtocolError(
      "remote does not advertise a default branch",
    )
  }
  if refname != "refs/heads/main" {
    raise @object.GitError::ProtocolError(
      "async pull requires refs/heads/main as the remote default branch",
    )
  }
  if current == target {
    return Unchanged(current)
  }
  let shallows = read_shallow_boundaries(fs, git_dir)
  let base_objects = load_pack_objects(fs, git_dir)
  base_objects.append(load_loose_objects(fs, git_dir))
  let request = match version {
    V2 =>
      @protocol.build_fetch_request_v2(
        "git/moonbit",
        [target],
        0,
        filter=NoFilter,
        haves=[current],
        shallow=shallows,
      )
    V0 =>
      @protocol.build_fetch_request_v0(
        "git/moonbit",
        [target],
        capabilities,
        haves=[current],
        shallow=shallows,
      )
  }
  let response = @protocol.upload_pack_request_with_http(
    remote,
    request,
    version == V2,
    http_post,
  )
  let fetch = match version {
    V2 => @protocol.parse_fetch_response_v2(response)
    V0 => @protocol.parse_fetch_response_v0(response)
  }
  let incoming = @pack.parse_packfile_with_bases(fetch.pack, base_objects)
  let store = @repo.ObjectStore::from_pack(base_objects)
  store.add_objects(incoming)
  if !commit_is_ancestor(store, current, target) {
    raise @object.GitError::InvalidObject("Non-fast-forward pull")
  }
  let before = @repo.checkout_commit(store, current)
  let after = @repo.checkout_commit(store, target)
  let index_path = @bit.join_path(git_dir, "index")
  if fs.kind(index_path) != File ||
    !@repo.index_matches_commit(store, current, fs.read_file(index_path)) {
    raise @object.GitError::IoError(
      "local index changes would be overwritten by pull",
    )
  }
  let created_directories = apply_worktree_changes(fs, root, before, after)
  let shallow_boundaries = @repo.update_shallow_boundaries(
    shallows,
    fetch.shallow,
    fetch.unshallow,
  )
  try
    write_repository_state(
      fs, root, store, target, incoming, shallow_boundaries,
    )
  catch {
    error => {
      let changed = changed_worktree_paths(before, after)
      try
        restore_worktree_changes(fs, root, before, changed, created_directories)
      catch {
        rollback_error =>
          raise @object.GitError::IoError(
            "pull failed: \{error}; restoring the worktree also failed: \{rollback_error}",
          )
      } noraise {
        _ => raise error
      }
    }
  } noraise {
    _ => ()
  }
  Updated(from=current, to=target)
}
