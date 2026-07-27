///| Git shallow-boundary metadata.

///|
pub fn read_shallow_boundaries(
  fs : &@types.RepoFileSystem,
  git_dir : String,
) -> Array[@object.ObjectId] {
  let path = join_path(git_dir, "shallow")
  if !fs.is_file(path) {
    return []
  }
  let data = fs.read_file(path) catch { _ => Bytes::default() }
  let boundaries : Array[@object.ObjectId] = []
  for line_view in @utf8.decode_lossy(data[:]).split("\n") {
    let line = line_view.trim().to_owned()
    if line.length() != 40 {
      continue
    }
    let id = @object.ObjectId::from_hex(line) catch { _ => continue }
    boundaries.push(id)
  }
  boundaries
}

///|
pub fn apply_shallow_updates(
  fs : &@types.FileSystem,
  rfs : &@types.RepoFileSystem,
  git_dir : String,
  shallow : Array[@object.ObjectId],
  unshallow : Array[@object.ObjectId],
) -> Unit raise @object.GitError {
  if shallow.length() == 0 && unshallow.length() == 0 {
    return
  }
  let boundaries = update_shallow_boundaries(
    read_shallow_boundaries(rfs, git_dir),
    shallow,
    unshallow,
  )
  let path = join_path(git_dir, "shallow")
  if boundaries.length() == 0 {
    if rfs.is_file(path) {
      fs.remove_file(path)
    }
    return
  }
  fs.write_string(
    path,
    [ for id in boundaries => id.to_hex() ].join("\n") + "\n",
  )
}

///|
/// Apply server-provided shallow and unshallow updates to a boundary set.
pub fn update_shallow_boundaries(
  current : Array[@object.ObjectId],
  shallow : Array[@object.ObjectId],
  unshallow : Array[@object.ObjectId],
) -> Array[@object.ObjectId] {
  let boundaries : Map[String, @object.ObjectId] = Map([])
  for id in current {
    boundaries[id.to_hex()] = id
  }
  for id in unshallow {
    boundaries.remove(id.to_hex())
  }
  for id in shallow {
    boundaries[id.to_hex()] = id
  }
  let result = [ for _, id in boundaries => id ]
  result.sort_by((a, b) => String::compare(a.to_hex(), b.to_hex()))
  result
}
