# 04 — Control Rig, Procedural Animation & Faker Body Harmonics

---

## 1. Golden Rule: Never Mutate Skeleton Bones Directly in Gameplay
- All procedural gameplay animation, locomotion, harmonics, hit reactions, and look-at adjustments manipulate **Rig Controls** (`Rig_Control_Transform` in `ControlRig`), **never** raw skeleton bones directly.
- Bones may be **read** (e.g., to inspect world positions/velocities or hit locations), while **Stage 5 (Full-Body IK Solver)** solves the final modified Rig Controls into bone matrices once at the end of the pipeline.

---

## 2. The 5-Stage Procedural Control Rig Pipeline (`plugins/control_rig/`)

### Stage 1: Base Pose + Action Sub-Layer + Aim Pre-Lean + Per-Control Intent & Armor
- Evaluates the current base pose (`.mhpose` / `.mhanim` clip) and blends any active upper-body or full-body action sub-layer.
- **Animation Signals**: Generic timeline event markers (`time`, `event_name: string`, `payload: string`) fire callbacks as the playhead crosses them (never hardcode specific gameplay event names in the editor UI).
- **Per-Control Animation Intent & Poise/Armor (`Control_Intent_State`)**:
  - Instead of authoring separate "weakened", "drunk", or "super-human" animations, each Rig Control carries:
    - `intent_weight: f32`: How strongly the control prioritizes reaching the authored pose (`1.0` on the striking fist = primary intent; `0.25` on secondary body controls = loose/sloppy follow-through).
    - `intent_tier: f32`: Global mental override multiplier (Tier 1 = normal human; Tier 2 = adrenaline/braced; Tier 3 = full override regardless of fatigue).
    - `armor_value: f32`: Per-control poise/hyper-armor during an active action window. If an incoming impact hits a limb whose `armor_value >= impact_poise_damage`, the limb tanks/clashes through the hit; if it strikes an unarmored limb (`armor_value < impact`), that limb yields or staggers.

### Stage 2: Procedural Locomotion Layer
- Drives foot placement, stride phase, pelvis bob/tilt, and center-of-mass balance over the support polygon.
- Tracks which leg is currently in **swing phase** vs. **stance/plant phase** so impacts to a landing stride leg can trigger a realistic trip/stumble when balance is broken.

### Stage 3: Faker Body Harmonics (Dual-Harmonic Pulse + Flesh Oscillation + Velocity Bracing)
- **Dual Harmonics**:
  1. **Skeletal Shock Pulse (High-Frequency Rigid Impulse)**: Short, sharp, critically-damped shockwave transmitted through rigid bone chains on hard ground stops, landings, or parries (`pulse_vel`, `pulse_stiffness`, `pulse_damping`).
  2. **Soft-Tissue / Flesh Oscillation (Under-Damped Spring)**: Continuous natural breathing micro-sway plus secondary soft-tissue wobble and follow-through (`osc_pos`, `osc_vel`, `osc_frequency`, `osc_damping`).
- **Muscle Tension (`brace_tension`) & Multi-Velocity Pose Array**:
  - When bracing (`brace_tension -> 1.0`), stiffness increases and external velocities are suppressed.
  - When muscles relax (`brace_tension -> 0.0`), a weighted array of velocity channels (linear inertia, angular momentum, centrifugal swing, gravity droop) drives the Rig Controls naturally.

### Stage 4: Hit React, Protective Pose Matching & Fake Ragdoll ("Fake Motors")
- **Continuous Harmonics**: Body harmonics never turn 100% off, even in cutscenes or during falls.
- **Hit React vs. Poise/Armor**:
  - Evaluates impact impulse against the struck control's `armor_value` and `brace_tension`.
  - **Partial Stagger**: Rotates torso/shoulder, disrupts aim, optionally drops held item if hand grip poise is exceeded, and blends recovery while staying in staggered locomotion.
  - **Full Knockdown / Fake Ragdoll**: When impact exceeds balance/recovery thresholds (or takes out a landing stride leg), transitions via delegate math block to Fake Ragdoll.
- **Predictive Pose Matching & Fake Motors**:
  - Predicts control positions/velocities a short horizon ahead ($t + \Delta t$) and scores candidate protective poses (e.g., arms shielding head, curled torso, stumble catch) to select the closest natural target pose.
  - Drives Rig Controls toward that protective pose using per-limb **Fake Motor Strength** (`motor_strength: f32`), so healthy/stronger limbs reach protective targets faster than stunned or injured limbs.

### Stage 5: Final Look-At Aim Polish & Full-Body IK Solve (`HumanoidIkSolver`)
- Applies final precision look-at/aim polish to head, chest, and weapon/hand controls (scaled by current stagger/focus weight).
- Feeds all final Rig Control transforms into [`HumanoidIkSolver`](file:///c:/Users/RagingWargun/Desktop/moonhug-main/plugins/control_rig/humanoid_ik.odin) (`solve_two_bone_ik`, spine/neck distribution, foot/hand twist, finger curl) to write the final skinning matrices.

---

## 3. Existing Control Rig & Gore Modules (`plugins/control_rig/`)
- [`component_control_rig.odin`](file:///c:/Users/RagingWargun/Desktop/moonhug-main/plugins/control_rig/component_control_rig.odin): `ControlRig`, `HumanoidIkSolver`, `GoreZoneCap`, `ArmatureDeformedMesh`, `ControlRigSequencer`.
- [`pose_library.odin`](file:///c:/Users/RagingWargun/Desktop/moonhug-main/plugins/control_rig/pose_library.odin): `.mhpose` JSON hand/body pose library.
- [`editor/collider_placer.odin`](file:///c:/Users/RagingWargun/Desktop/moonhug-main/plugins/control_rig/editor/collider_placer.odin): Anatomical bone-fitted hitboxes and ragdoll constraint generator.
- [`editor/ghoul_gore_editor.odin`](file:///c:/Users/RagingWargun/Desktop/moonhug-main/plugins/control_rig/editor/ghoul_gore_editor.odin): Soldier of Fortune II *Ghoul* multi-zone gore and CSG wound carving.
