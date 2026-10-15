# Drawing order: how to put long hair behind the neck

Reasoned from `main` at `bc784d5`. Option 4 was chosen and **shipped**; see "As built" at the end for where it differs from the sketch.

## The problem

Long hair is one accessory of the Head. Its back sheet has to draw behind the Neck and the Head; its fringe in front
of the Head. Wanted stack, back to front:

    Torso · Hair (behind) · Neck · Head · Hair (fringe)

## How order is decided today

- `Drawing.parts` is one flat list, back to front, holding parts and accessories. It is the draw order and is
  written as the file's `drawOrder` (CharacterFormat.swift:116). That list already *is* a z-order: the Stack view
  edits it directly.
- An accessory can sit anywhere in it. Moving its part carries it by as many places (`Drawing.placing`), and one
  dragged away shows a "moved" badge.
- **Draw Behind Owner** (`VectorShape.isBehindOwner`) splits an accessory's marked shapes into a piece drawn
  *immediately* behind the owner's art (`Drawing.drawStack`, DrawingEditor+Accessories.swift:29). That is the
  gap: the behind piece is pinned to the Head, so it lands between Neck and Head, over the neck.
- Clipping and group clipping are per layer, and behind shapes clip only to each other.

What works today is two accessories (Hair Back dragged below Neck, Hair Front). The cost is that one piece of hair
is two layers to select, hide and recolour, and later two outfit slots to keep in sync. Avoiding exactly that is
why Draw Behind Owner exists for the hat.

## Options

### 1. Character-wide z-index (the first idea)

Every part gets a number; draw order is the sort. **Against:** the flat stack is already a total order and drag to
reorder is a nicer way to edit it than typing numbers. A number re-encodes the same thing with gaps, ties to
break, renumbering when the gaps run out, and no visual cue for what "35" means. It also fights the ownership
tree: moving the Head wouldn't carry its accessories unless every number is rewritten. It doesn't solve the hair
on its own either; you'd still need hair split into two things with two numbers.

### 2. Named depth bands with local order

Fixed bands (Back, Body, Front), each with its own little stack; a layer or piece picks a band. **For:** "back
hair" is one setting. **Against:** a second ordering system beside the stack, and the hair case still needs order
*within* Body (Neck below Head), so the stack never goes away. Bands are global, so a band that's right for hair is
wrong for an arm swinging behind the body. The format and a Spine export flatten them straight back to one list.
Good for big multi-character scenes, more than one character needs.

### 3. Above/below constraints

"Hair (behind) below Neck", "Neck below Head", and a solver produces the stack. **For:** survives reordering of
unrelated parts. **Against:** the order becomes derived, so a drag has to add or rewrite constraints, cycles need
an error state, and the user can no longer see why something draws where it does. The anchored behaviour that
matters (accessories travel with their part) is already given by `placing`.

### 4. Split one layer across several stack slots (recommended)

Generalise Draw Behind Owner: an accessory's behind shapes become a **behind piece** with its **own row in the
draw order** that can be dragged anywhere, instead of a piece pinned just behind the owner. Still one layer for
ownership: it selects, hides, locks, recolours and (later) swaps with an outfit as one; only stacking has two
entries.

- Default stays today's: turning on Draw Behind Owner puts the behind piece just behind the owner, so the hat and
  the robot's antenna don't change.
- The Stack view lists "Hair (behind)" as its own row; drag it below Neck. The Tree view stays as it is.
- Reordering: the behind piece stays just behind the layer it was dropped on (see "As built").
- Clipping stays as it is: back shapes clip only to back shapes.
- Format: one optional key on the slot, so older files read unchanged and Robo re-saves byte for byte (see "As
  built"). A Spine export already has to split such an accessory into two slots.
- Scope: two pieces (back, front), not N. If a third depth turns up (hair strand in front of the shoulder but
  behind the arm), that's a second accessory, which is fine for a rare case.

## Why 4

It keeps one source of truth (the flat stack the app, file and Spine already share) and only lifts the one
restriction that blocks the hair: where the behind piece may go. Bands and constraints add a second system to explain
to fix one case; a z-index is the stack with worse editing.

## Hair, worked through

1. Hair is one accessory of Head, drawn as one layer: back sheet and fringe.
2. Select the back sheet shapes, turn on Draw Behind Owner. Stack: Torso · Neck · Hair (behind) · Head · Hair.
3. In the Stack view drag "Hair (behind)" below Neck. Stack: Torso · Hair (behind) · Neck · Head · Hair.
4. Move the Torso or the Head later: Hair (behind) stays just behind the Neck, so the neck stays between.
5. An outfit swaps Hair for a ponytail: one slot, both pieces come from the new art.

## As built

- The behind piece's place is stored as the layer it draws just behind (`Part.behindLayer`, `"behindSlot"` on the
  slot in the file), not as its own entry in `drawOrder`. That keeps `drawOrder` a plain list of slots for other
  readers, and makes reordering simple: the piece follows the layer it was dropped on. Nil, or the owner, is the
  old behaviour.
- Dragging the "(behind)" row in the Stack view sets it to the layer on the row above the drop; dropped under
  another accessory's behind row, it shares that row's layer; dropped at the top, nothing changes.
- Deleting that layer, or detaching the accessory, puts the piece back behind the owner. Long-press the row for
  Draw Just Behind (owner).
- Robo has no neck, so the example file doesn't use `behindSlot`; `BehindLayerTests` round-trips it.
