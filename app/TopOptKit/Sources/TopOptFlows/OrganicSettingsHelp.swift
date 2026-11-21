// OrganicSettingsHelp — ★ his iPad notes 11-20 (img7): "There is barely ANY information on what each setting actually DOES.
// There should be a couple words under each setting ... And there should always be an (i) next to settings to go into further
// details about each one." The words are LatticeReview's help sheet (organic/land/organic-settings-help.md, reviewed, from
// the engine's code at bc34b79c), as written for him; Look's are the app's own after his 11-20 pick (his 1-100 rule).
// Each setting: a GREY LINE under it (his 11-20 correction: "This should be at most 5 words! Twelve is way too much!")
// and an (i) TEXT (three to six plain sentences). Four number labels carry "(0 = off)" (five words cannot also say it).
import Foundation

public enum OrganicSettingsHelp {
    public struct Entry: Equatable, Sendable {
        public let grey: String
        public let info: String
    }

    /// The panel's labels, exactly as the panel shows them.
    public static let entries: [String: Entry] = [
        "Auto / Manual": .init(
            grey: "Auto decides. Manual shows all.",
            info: "Auto sets every Organic setting for you from your part and the Look slider. Manual shows each setting so "
                + "you can change it yourself; it starts from the values Auto would use. You can go back to Auto at any time."),
        "Organic": .init(
            grey: "Follows forces, or grows up.",
            info: "Traced draws each vine along the lines of force running through the part, giving an even, orderly lattice "
                + "tied to how the part is loaded. Grown grows the vines up from the bed and in from the walls, branching like "
                + "a plant; it looks more natural, and every layer stands on the one below. Both are checked for strength the "
                + "same way. Try Grown for looks and Traced for a tidier structural lattice."),
        "Look": .init(
            grey: "1 open. 100 nearly solid.",
            info: "Look sets how much lattice there is. At 1 the cells are the largest your part measures, for the most open "
                + "lattice; at 100 every cell is the smallest your printer can make, so the area is almost solid. It starts at "
                + "15, close to the lattice Auto has always made. Higher is stronger and finer, but heavier and slower to print. "
                + "Strut thickness stays the same."),
        "Finish": .init(
            grey: "Bare vines, skin, or closed.",
            info: "None leaves the vines as they are where the face cuts them. Skin lays a web of thin strands on the face, cut "
                + "flat, joined down to the vines below; it gives the surface its own pattern and protects the vine ends. Solid "
                + "closes the face with a solid layer, which is smooth and strong but hides the lattice. On a face with Skin or "
                + "Solid the surface is always flat: depth variation does not apply there."),
        "Skin thickness": .init(
            grey: "Auto, or 0.9–3 mm.",
            info: "How thick the strands of the skin web are. Auto makes each as thick as the thinner vine it joins. Thicker "
                + "strands make a stronger, heavier skin that covers more of the face; thinner ones look lighter. It can never "
                + "be thinner than your printer's thinnest strut."),
        "Skin density": .init(
            grey: "1 sparse, 6 dense.",
            info: "Where a vine reaches the face, the skin joins it to its neighbours. Density says how many: 1 joins only the "
                + "nearest ones, for a sparse open web; 6 joins many more, for a dense web that covers most of the face. Denser "
                + "skins are heavier and take longer to print. 3 is the usual."),
        "Gradient": .init(
            grey: "What makes cells smaller.",
            info: "With Stress and shape, the cells get smaller and the struts thicker where the part works hardest, and near "
                + "its edges. With Shape only, the forces are ignored for sizes: the cells start at their largest everywhere and "
                + "only get smaller near the edges and under floating parts. The vines still run along the forces either way. "
                + "Use Shape only for parts that carry no real load."),
        "Cell size": .init(
            grey: "Vine distance. Max 200 mm.",
            info: "How far apart the vines are. The first number is used where the part works hardest (and near edges), the "
                + "second where it is quiet. Smaller cells mean more vines: stronger and finer, but heavier and slower to print, "
                + "and a bigger file. Larger cells are lighter and quicker. The smallest allowed depends on the strut thickness, "
                + "so a gap is always left to print. Auto Sweep measures your part for you."),
        "Strut thickness": .init(
            grey: "Vine thickness. Max 50 mm.",
            info: "How thick each vine is. With a range, the first number is used where the part is quiet and the second where "
                + "it works hardest. Thicker vines are stronger and stiffer but heavier and slower to print. The thinnest allowed "
                + "is two printed lines. When the strength check finds a weak vine, strengthening thickens it up to the second "
                + "number; it goes past that only as a last resort, never beyond twice that number, and tells you where. Auto "
                + "Sweep starts from your part's size."),
        "Seeds (feet apart) (0 = off)": .init(
            grey: "Usually 1.5–4. Max 20.",
            info: "Grown vines start from feet on the bed. This keeps the feet at least this many spacings apart, so they do "
                + "not crowd each other. Lower: more vines start close together, a busier lattice. Higher: fewer vines, more "
                + "open at the bottom. 0 keeps every foot. 2.5 is the usual."),
        "Wall seeds": .init(
            grey: "Vines also start from walls.",
            info: "As well as from the bed, vines start from the side walls of the area and grow inward. This fills the lattice "
                + "near the walls and ties it to them, which helps strength. Off: vines grow only from the bed. Crossing vines "
                + "need it on."),
        "Wall seed gap (0 = off)": .init(
            grey: "Usually 1–3. Max 20.",
            info: "Keeps the vines that start on the walls at least this many spacings apart. With a range, they may start "
                + "closer (the second number) where the part works hardest. Lower: more wall vines, a denser edge. Higher: "
                + "fewer. 0 lets them start anywhere. Needs Wall seeds on."),
        "Crossing vines": .init(
            grey: "Wall vines brace the others.",
            info: "Vines that start on the walls and climb across the floor vines at an angle, after those have grown. They "
                + "brace the lattice sideways, like cross-bracing in a frame. Off: a simpler lattice, weaker sideways. They "
                + "never climb steeper than 45 degrees, so they print without support."),
        "Crossing gap": .init(
            grey: "Usually 1–3. Max 20.",
            info: "Keeps the crossing vines at least this many spacings apart where they start. With a range, closer (the "
                + "second number) where the part works hardest. Lower: more crossing vines and more bracing; higher: fewer. "
                + "Needs Crossing vines on."),
        "Roots (0 = off)": .init(
            grey: "Usually 1–3. Max 20.",
            info: "Roots run along the bed from each vine's foot before dipping into it, like a plant's roots. They give each "
                + "vine a wider, firmer footing on the bed and tie neighbouring feet together. The number is how long they run, "
                + "in spacings. 0 means no roots. Longer roots add material and print time. Try 1 or 2."),
        "Top branches (0 = off)": .init(
            grey: "Usually 1–2. Max 20.",
            info: "When a vine reaches the top face, it can run along it, level, for this many spacings instead of stopping. "
                + "This joins the vines under the top face, which spreads loads pressing on it. 0 means vines stop at the top. "
                + "Longer runs add material. Try 1 or 2."),
        "Stress follow": .init(
            grey: "Vines steer along the forces.",
            info: "On: as Grown vines grow, they steer along the lines of force in the part, so they carry load better. Off: "
                + "they grow toward the faces of the area instead, a more even, plant-like spread. On is better for strength."),
        "Flat ties": .init(
            grey: "Level ties that print cleanly.",
            info: "Ties are short struts that join neighbouring vines so they hold each other. Flat ties are always level, so "
                + "your printer draws them as straight bridges, which print cleanly; more of them go where the part works "
                + "hardest. Off: Traced lays no ties of this kind, and Grown keeps only its own sloping ties. On is recommended."),
        "Flat tie gap": .init(
            grey: "Usually 0.5–2. Max 20.",
            info: "A tie starts every this many spacings along a vine. With a range, ties come closer together (the second "
                + "number) where the part works hardest. Lower: more ties, a stiffer, denser lattice; higher: fewer ties, more "
                + "open. Needs Flat ties on."),
        "Grade to shape reach (0 = off)": .init(
            grey: "Usually 0.5–2. Max 10.",
            info: "Near the outside of the area the cells get smaller, so the lattice fits the shape closely. This sets how far "
                + "in from the faces that reaches: 2 reaches twice as far, 0.5 half as far, 0 turns it off. Higher means more "
                + "small cells: stronger edges, more material and print time. 1 is usual."),
        "Detect floating parts": .init(
            grey: "Props up overhanging solid.",
            info: "Finds solid pieces of your part that would hang over the lattice with nothing under them, and makes the cells "
                + "under them small and adds supports from the bed or the solid below, so they print and are held. Off: those "
                + "pieces may sag or fail to print. Keep it on unless your part has none."),
        "Simulate stresses on unstressed walls": .init(
            grey: "Invents stress for richer patterns.",
            info: "Walls that carry no real load get no stress, so their lattice is plain. This makes up a gentle stress pattern "
                + "on them, spreading from a few points (the foci, set per wall in Selections, 1 to 5), so the vines vary and "
                + "curve there too. It is for looks only, which is why it is offered in Aesthetic only. 3 foci is the usual."),
        "Depth variation": .init(
            grey: "Up to 1 mm out.",
            info: "On: where the vines meet an open face, they keep a little of their round tops, up to 1 mm out of the face, so "
                + "the surface has depth and texture. Off: every vine is sliced flat at the face, for a smooth, even surface. "
                + "Faces that carry a load or are fixed are always flat. It adds a little to the part's size at those faces."),
        "Extra spacing between vines": .init(
            grey: "Will likely lose strength.",
            info: "Keeps the traced vines further apart from each other, so the lattice looks cleaner and more even. It will "
                + "likely lose strength, because fewer vines carry the load: fine for Aesthetic, and it may still work in "
                + "Structural if there is strength to spare. It only changes Traced lattices."),
        "Link thickness": .init(
            grey: "0.5 to 2. Usually 1.",
            info: "Where two vines cross, a short link joins them so they hold each other instead of passing through. This sets "
                + "how thick that link is, compared with the thinner of the two vines. Thicker links make stronger joints and "
                + "add a little material; thinner ones look lighter. 1 is usual."),
        "Longest strut without a joint (0 = off)": .init(
            grey: "Usually 8–20. Max 40.",
            info: "A long, thin strut can bend or buckle. When a strut is longer than this many times its own thickness, a "
                + "brace is added to join it to a neighbour. Lower: more braces, stiffer and stronger, more material. Higher: "
                + "fewer braces. 0 adds none. 10 is a good start."),
    ]

    /// ★ his 11-20: "This needs to be openable and not ALWAYS visible ... At most 5 words for the link to the glossary".
    public static let glossaryLink = "What these words mean"
    public static let glossaryTitle = "What these words mean"
    public static let glossary = [
        "Vine: one of the long, curving strands the lattice is made of. Vines branch, meet and cross like plant stems.",
        "Strut: one piece of a vine between two joints.",
        "Cell size: the room between neighbouring vines. Small cells: many vines, stronger, heavier, slower to print.",
        "A spacing: the cell size at that place. \"2 spacings\" is twice the distance between neighbouring vines there.",
        "Thinnest strut: two printed lines side by side; nothing thinner prints.",
        "Auto Sweep and Auto: the app works out a range, or one number, from your part. Manual Sweep and Manual: you type it.",
        "A sweep: a range. One end where the part works hardest, the other where it is quiet.",
        "Look: 1 is the most open lattice your part allows, 100 is almost solid. It starts at 15.",
        "Traced: vines follow the lines of force, like grain in wood. Grown: vines grow up from the bed like a plant.",
        "Finish: how the open face ends. None: bare vines. Skin: a web of thin strands. Solid: closed.",
        "Ties: short level struts joining neighbouring vines. Links: the joins where two vines cross.",
        "Roots, top branches, wall seeds, crossing vines (Grown): vines spreading along the bed, along the top, from the walls, "
            + "and across the others to brace them.",
    ].joined(separator: "\n\n")

    public static func entry(_ label: String) -> Entry? { entries[label] }
}
