# Tree Coral — Roblox mesh export

## Fix (one FBX per size)

Export **Main + Accent together** in one file per size (same pattern as Zoas):

| File | Collection | Contents |
|------|------------|----------|
| `TreeSmall.fbx` | `Tree Small` | Joined Main meshes + joined icosphere accents |
| `TreeMed.fbx` | `Tree Medium` | Main + Accent |
| `TreeLarge.fbx` | `Tree Large` | Main + Accent |

### Blender export

```python
exec(open(r"C:\Game Dev\Ocean TD\Models\Tree Coral\export_tree_coral_fbx.py").read())
```

Requires collections **`Tree Small`**, **`Tree Medium`**, **`Tree Large`** with:
- **Main** — any mesh whose name starts with `Main` (e.g. `Main`, `Main2`, `Main__`)
- **Accent** — icospheres and other non-Main meshes in the collection

### Roblox Studio import

1. Import each combined FBX into `ReplicatedStorage.Coral.TreeCoral`
2. Rename imported Models to **`TreeSmall`**, **`TreeMed`**, **`TreeLarge`**
3. Confirm each Model has MeshParts named **`Main`** and **`Accent`**
4. Set default materials/colors once on those template parts

Do **not** import Main and Accent as separate FBX files — Roblox re-centers each import and they will misalign.

### Roblox Studio layout (game)

Move imported models from a staging folder into:

```
ReplicatedStorage.Coral.TreeCoral
  TreeSmall   (Model — MeshParts Main*, Accent, Food1)
  TreeMed     (Main*, Accent, Food1–2)
  TreeLarge   (Main*, Accent, Food1–4, Collider×N walk volumes)
```

`*` Main may import as `Main.003` etc. — game code matches any name containing `Main`.

**Walk collision:** Add hidden **`Collider`** parts under a size model (e.g. 8 under `TreeLarge`). At runtime the game clones them, welds them to the coral, and disables mesh collision — players stand on Colliders only.

Game treats Tree Coral like Zoas: dual main/accent paint, random scale jitter, **no** placement rotation. Same combat stats as Zoas. Food markers drive ammo spawn positions per size tier.

