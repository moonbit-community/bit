///| Fast-forward pull over asynchronous HTTP and filesystem adapters.

///|
pub(all) enum PullResult {
  Unchanged(@object.ObjectId)
  Updated(from~ : @object.ObjectId, to~ : @object.ObjectId)
} derive(Eq, Debug)

///|
async fn read_ref(fs : &AsyncFileSystem, path : String) -> @object.ObjectId? {
  if fs.kind(path) != File {
    return None
  }
  let value = fs.read_file(path)
  Some(
    @object.ObjectId::from_hex(@utf8.decode_lossy(value[:]).trim().to_owned()),
  ) catch {
    _ => None
  }
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
    if !value.is_empty() {
      result.push(@object.ObjectId::from_hex(value))
    }
  }
  result
}

///|
fn pull_parent_dir(path : String) -> String {
  match path.rev_find("/") {
    None => "."
    Some(0) => "/"
    Some(index) => path[:index].to_owned()
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
) -> Unit {
  let changed = changed_worktree_paths(before, after)
  verify_worktree_changes(fs, root, before, changed)
  for path in changed {
    let full_path = @bit.join_path(root, path)
    match after.get(path) {
      None => if fs.kind(full_path) == File { fs.remove_file(full_path) }
      Some(content) => {
        if fs.kind(full_path) == Directory {
          fs.remove_empty_dir(full_path)
        }
        fs.mkdir_p(pull_parent_dir(full_path))
        fs.write_file(full_path, content)
      }
    }
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
fn checkout_index(
  store : @repo.ObjectStore,
  commit : @object.ObjectId,
  remote : String,
) -> Bytes raise @object.GitError {
  let memory = @io.TestFs::new()
  @repo.materialize_clone_to_fs(
    store, commit, "refs/heads/main", remote, memory, "/repo",
  )
  memory.read_file("/repo/.git/index")
}

///|
async fn write_repository_state(
  fs : &AsyncFileSystem,
  root : String,
  remote : String,
  store : @repo.ObjectStore,
  commit : @object.ObjectId,
  objects : Array[@object.PackObject],
) -> Unit {
  let git_dir = @bit.join_path(root, ".git")
  let canonical_pack = @pack.create_packfile(objects)
  let id = pack_id(canonical_pack)
  let pack_dir = @bit.join_path(git_dir, "objects/pack")
  let base = "pack-\{id.to_hex()}"
  fs.mkdir_p(pack_dir)
  fs.write_file(@bit.join_path(pack_dir, base + ".pack"), canonical_pack)
  fs.write_file(
    @bit.join_path(pack_dir, base + ".idx"),
    @pack.build_pack_index(canonical_pack),
  )
  fs.write_file(
    @bit.join_path(git_dir, "index"),
    checkout_index(store, commit, remote),
  )
  let remote_ref = @bit.join_path(git_dir, "refs/remotes/origin/main")
  fs.mkdir_p(pull_parent_dir(remote_ref))
  fs.write_file(remote_ref, @utf8.encode("\{commit.to_hex()}\n"))
  let local_ref = @bit.join_path(git_dir, "refs/heads/main")
  fs.mkdir_p(pull_parent_dir(local_ref))
  // Update the checked-out ref last so interrupted pulls remain detectable.
  fs.write_file(local_ref, @utf8.encode("\{commit.to_hex()}\n"))
}

///|
/// Fast-forward the `main` branch of an existing repository using asynchronous
/// HTTP and filesystem adapters. The server may return a thin pack because the
/// current commit is advertised as a `have`; received objects are stored in a
/// self-contained local pack.
pub async fn pull_main_http(
  fs : &AsyncFileSystem,
  root : String,
  remote : String,
  http_get : async (String, Map[String, String]) -> (@types.HttpResponse, Bytes) raise @object.GitError,
  http_post : async (String, Bytes, Map[String, String]) -> (
    @types.HttpResponse,
    Bytes,
  ) raise @object.GitError,
) -> PullResult {
  let git_dir = @bit.join_path(root, ".git")
  let local_ref = @bit.join_path(git_dir, "refs/heads/main")
  guard read_ref(fs, local_ref) is Some(current) else {
    raise @object.GitError::IoError(
      "async pull requires an existing refs/heads/main checkout",
    )
  }
  let (refs, _, _, symrefs) = @protocol.discover_upload_refs_with_http(
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
  let pack = @protocol.fetch_pack_with_haves_with_http(
    remote,
    [target],
    [current],
    true,
    0,
    NoFilter,
    http_get,
    http_post,
    shallows~,
  )
  let incoming = @pack.parse_packfile_with_bases(pack, base_objects)
  let store = @repo.ObjectStore::from_pack(base_objects)
  store.add_objects(incoming)
  if !commit_is_ancestor(store, current, target) {
    raise @object.GitError::InvalidObject("Non-fast-forward pull")
  }
  let before = @repo.checkout_commit(store, current)
  let after = @repo.checkout_commit(store, target)
  apply_worktree_changes(fs, root, before, after)
  write_repository_state(fs, root, remote, store, target, incoming)
  Updated(from=current, to=target)
}
