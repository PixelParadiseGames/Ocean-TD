# Zoas — Roblox mesh export

## Problem (separate Main + Accent FBX)

Importing `ZoaSmall_Main.fbx` and `ZoaSmall_Accent.fbx` as **two files** makes Roblox re-center each mesh on its own. They will look stretched/misaligned no matter what runtime code does.

## Fix (one FBX per size)

Export **Main + Accent together** in one file per size:

| File | Contents |
|------|----------|
| `ZoaSmall.fbx` | Main + Accent (1 zoa set) |
| `ZoaMed.fbx` | Main + Accent (3 sets merged) |
| `ZoaLarge.fbx` | Main + Accent (6 sets merged) |

### Blender export

```python
exec(open(r"C:\Game Dev\Ocean TD\Models\Zoas\export_zoas_fbx.py").read())
```

Requires collections: `Zoa Small`, `Zoa Med`, `Zoa Large` with Main/Accent mesh objects.

### Roblox Studio import

1. Delete old split templates (`ZoaSmall_Main`, `ZoaSmall_Accent`, etc.)
2. Import each combined FBX into `ReplicatedStorage.Coral.Zoas`
3. Rename imported Models to **`ZoaSmall`**, **`ZoaMed`**, **`ZoaLarge`**
4. Confirm each Model has MeshParts named **`Main`** and **`Accent`**
5. Set default materials/colors once on those template parts

Game code reads the relative offset from the template Model (Sea Fan pattern) — no runtime alignment fix needed.

### Legacy split FBX

The old `ZoaSmall_Main.fbx` / `ZoaSmall_Accent.fbx` files are deprecated. Do not import them.
