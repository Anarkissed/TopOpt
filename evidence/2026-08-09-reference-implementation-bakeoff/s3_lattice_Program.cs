// S3 of task 2026-08-09-reference-implementation-bakeoff — PicoGK.
//
// THE QUESTION (task S3): take a design of his, build a GRADED lattice with
// LEAP 71's LatticeLibrary driven by the optimizer's own field, and measure
//   (b) does the strut thickness vary CONTINUOUSLY, and what happens at the
//       transitions PR 302 measured a seam at;
//   (c) what PicoGK holds in memory, what it writes, and what the export weighs,
//       against his four variants' 102,972,348 triangles and ~5.1 GB;
//   (d) PicoGK does no FEA — where would the certificate have to sit.
//
// ★ THE MAINTAINERS' OWN RECIPE, FOLLOWED LITERALLY. PicoGK discussion #29:
// "Read the 3D field from your simulation — if you store it in a ScalarField,
// you can look up the simulation value at the relevant point in space. Use the
// value you read from the position to modulate the wall thickness." That is
// exactly `FieldBeamThickness` below: a `PicoGK.ScalarField` holding core's own
// per-voxel density, and an `IBeamThickness` that reads it. LatticeLibrary's
// `IBeamThickness` interface is a single method `float fGetBeamThickness(Vector3)`,
// so the whole of the "new code" this task was told to watch for is ONE CLASS OF
// TWENTY LINES, and it is a lookup, not an algorithm.
//
// usage:
//   dotnet run -c Release -- <problem_dir> <rung.f64> <rung.stl> <out_dir> <cell_mm>

using System.Diagnostics;
using System.Globalization;
using System.Numerics;
using PicoGK;
using Leap71.ShapeKernel;
using Leap71.LatticeLibrary;

namespace S3Lattice;

/// <summary>core's per-voxel density, in a PicoGK ScalarField, as PicoGK
/// discussion #29 describes. Nothing is smoothed or re-gridded: SetValue is
/// called once per voxel centre at core's own spacing.</summary>
public sealed class DensityField
{
    public readonly int NX, NY, NZ;
    public readonly float H, OX, OY, OZ;
    public readonly double[] Rho;
    public ScalarField Field;

    public DensityField(string problemJson, string rhoPath)
    {
        string j = File.ReadAllText(problemJson);
        NX = (int)ReadNum(j, "\"nx\"");   NY = (int)ReadNum(j, "\"ny\"");
        NZ = (int)ReadNum(j, "\"nz\"");   H  = (float)ReadNum(j, "\"spacing_mm\"");
        var o = ReadArr(j, "\"origin_mm\"");
        OX = (float)o[0]; OY = (float)o[1]; OZ = (float)o[2];

        long n = (long)NX * NY * NZ;
        Rho = new double[n];
        using var fs = File.OpenRead(rhoPath);
        using var br = new BinaryReader(fs);
        for (long i = 0; i < n; i++) Rho[i] = br.ReadDouble();
        if (fs.Position != fs.Length)
            throw new Exception($"{rhoPath} is longer than {NX}x{NY}x{NZ} float64");
    }

    public void Build(Library lib)
    {
        Field = new ScalarField(lib);
        for (int k = 0; k < NZ; k++)
        for (int jj = 0; jj < NY; jj++)
        for (int i = 0; i < NX; i++)
        {
            float v = (float)Rho[((long)k * NY + jj) * NX + i];
            if (v <= 0f) continue;              // sparse: void carries no value
            Field.SetValue(Centre(i, jj, k), v);
        }
    }

    public Vector3 Centre(int i, int j, int k) =>
        new(OX + (i + 0.5f) * H, OY + (j + 0.5f) * H, OZ + (k + 0.5f) * H);

    /// <summary>trilinear read of the density at an arbitrary point, clamped to
    /// the grid. The lattice asks for thickness at points that are not voxel
    /// centres, so SOMETHING has to interpolate; doing it here, in the open,
    /// beats letting a nearest-voxel lookup quantise the grading invisibly.</summary>
    public double Sample(Vector3 p)
    {
        double fx = (p.X - OX) / H - 0.5, fy = (p.Y - OY) / H - 0.5, fz = (p.Z - OZ) / H - 0.5;
        int i0 = (int)Math.Floor(fx), j0 = (int)Math.Floor(fy), k0 = (int)Math.Floor(fz);
        double tx = fx - i0, ty = fy - j0, tz = fz - k0;
        double acc = 0;
        for (int dk = 0; dk <= 1; dk++)
        for (int dj = 0; dj <= 1; dj++)
        for (int di = 0; di <= 1; di++)
        {
            int i = Math.Clamp(i0 + di, 0, NX - 1);
            int j = Math.Clamp(j0 + dj, 0, NY - 1);
            int k = Math.Clamp(k0 + dk, 0, NZ - 1);
            double w = (di == 1 ? tx : 1 - tx) * (dj == 1 ? ty : 1 - ty) * (dk == 1 ? tz : 1 - tz);
            acc += w * Rho[((long)k * NY + j) * NX + i];
        }
        return acc;
    }

    static double ReadNum(string j, string key)
    {
        int i = j.IndexOf(key, StringComparison.Ordinal);
        int c = j.IndexOf(':', i) + 1;
        int e = c; while (e < j.Length && (char.IsDigit(j[e]) || j[e] is '-' or '+' or '.' or 'e' or 'E' || char.IsWhiteSpace(j[e]))) e++;
        return double.Parse(j[c..e].Trim(), CultureInfo.InvariantCulture);
    }
    static double[] ReadArr(string j, string key)
    {
        int i = j.IndexOf(key, StringComparison.Ordinal);
        int a = j.IndexOf('[', i) + 1, b = j.IndexOf(']', a);
        return j[a..b].Split(',').Select(s => double.Parse(s.Trim(), CultureInfo.InvariantCulture)).ToArray();
    }
}

/// <summary>★ THE WHOLE OF THE NEW CODE. LatticeLibrary's IBeamThickness is one
/// method taking a POINT; this returns a thickness read from core's density
/// field at that point. Because the interface is per-point rather than per-cell,
/// the thickness is a continuous function of position by construction and there
/// is no cell-to-cell quantisation to seam.</summary>
public sealed class FieldBeamThickness : IBeamThickness
{
    readonly DensityField m_x;
    readonly float m_fMin, m_fMax;
    readonly double m_fDriverMax;   // the field value that maps to full thickness
    public int Samples;                 // instrumentation: how often it is asked
    public double MinSeen = double.MaxValue, MaxSeen = double.MinValue;

    public FieldBeamThickness(DensityField x, float fMin, float fMax, double fDriverMax = 1.0)
    { m_x = x; m_fMin = fMin; m_fMax = fMax; m_fDriverMax = fDriverMax; }

    public float fGetBeamThickness(Vector3 vecPt)
    {
        double rho = Math.Clamp(m_x.Sample(vecPt) / m_fDriverMax, 0.0, 1.0);
        // ★ THE ONE MODELLING CHOICE, AND IT IS NOT CORE'S LAW. Strut thickness is
        // taken proportional to sqrt(field): for a strut lattice the relative
        // density goes roughly as (t/cell)^2, so sqrt is the crude inverse. core's
        // octet strut law is elsewhere and is NOT reproduced here, deliberately —
        // S3 asks whether the grading is CONTINUOUS and what it costs, not whether
        // PicoGK can be made to agree with core's strut sizing. Any monotone
        // function of the field would answer S3's question identically, because
        // what is measured below is the SIZE OF THE STEP between adjacent samples
        // relative to the range, and that is a property of the field.
        float t = m_fMin + (m_fMax - m_fMin) * (float)Math.Pow(rho, 1.0 / 2.0);
        Samples++;
        if (rho < MinSeen) MinSeen = rho;
        if (rho > MaxSeen) MaxSeen = rho;
        return t;
    }

    public void UpdateCell(IUnitCell xCell) { }
    public void SetBoundingVoxels(Voxels voxBounding) { }
}

public static class Program
{
    static void Report(string path, string text) { File.WriteAllText(path, text); }

    /// <summary>LatticeLibrary's OWN assembly function, from
    /// `Examples/Ex_LatticeLibraryRegularTask.cs`, unchanged except for the
    /// explicit `Library` (PicoGK 2.x's non-global API — the examples are
    /// written against `Library.Go`, which opens a GL viewer this run has no
    /// display for).
    /// ★ NOTE FOR THE ADOPTION COST: this four-line function is NOT in the
    /// LatticeLibrary package. It lives in the example code, and a user is
    /// expected to copy it. The library ships the three interfaces and the
    /// building blocks; the thing that combines them is a snippet.</summary>
    static Voxels voxGetFinalLatticeGeometry(
        Library         lib,
        ICellArray      xCellArray,
        ILatticeType    xLatticeType,
        IBeamThickness  xBeamThickness,
        uint            nSubSample = 2)
    {
        Lattice oLattice = new Lattice(lib);
        foreach (IUnitCell xCell in xCellArray.aGetUnitCells())
        {
            xBeamThickness.UpdateCell(xCell);
            xLatticeType.AddCell(ref oLattice, xCell, xBeamThickness, nSubSample);
        }
        return new Voxels(oLattice);
    }

    public static void Main(string[] args)
    {
        if (args.Length < 5)
        {
            Console.WriteLine("usage: s3_lattice <problem_dir> <rung.f64> <rung.stl> <out_dir> <cell_mm>");
            Environment.Exit(2);
        }
        string problemDir = args[0], rhoPath = args[1], stlPath = args[2], outDir = args[3];
        float fCellMM = float.Parse(args[4], CultureInfo.InvariantCulture);
        // args[5] — the field value that maps to full strut thickness. 1.0 for a
        // density field; the field's own maximum for a von Mises field.
        double fDriverMax = args.Length > 5 ? double.Parse(args[5], CultureInfo.InvariantCulture) : 1.0;
        // args[6] — PicoGK's voxel size. ★ THIS IS NOT HIS DESIGN VOXEL AND MUST
        // NOT DEFAULT TO IT. His design grid is 1.705 mm; his struts are 0.45 to
        // 2.4 mm. A lattice rendered at the design pitch cannot resolve its own
        // struts, and the triangle count that comes out of it is meaningless
        // against his 102,972,348. Passing a lattice-appropriate pitch is what
        // makes the file-size comparison in S3(c) like for like.
        float fVoxelArg = args.Length > 6 ? float.Parse(args[6], CultureInfo.InvariantCulture) : -1f;
        Directory.CreateDirectory(outDir);

        var sw = new StringWriter();
        void W(string s) { sw.WriteLine(s); Console.WriteLine(s); }

        var xField = new DensityField(Path.Combine(problemDir, "problem.json"), rhoPath);
        W("== S3 — PicoGK graded lattice from core's own density field ==");
        W("");
        W($"grid          {xField.NX} x {xField.NY} x {xField.NZ}, spacing {xField.H:F9} mm");
        W($"density file  {rhoPath}");
        W($"bounding STL  {stlPath}  ({new FileInfo(stlPath).Length:N0} bytes)");
        W($"cell size     {fCellMM:F3} mm  ({fCellMM / xField.H:F2} voxels)");
        W($"driver max    {fDriverMax:G6}  (the field value mapped to full strut thickness)");
        W("");

        // ★ VOXEL SIZE IS PICOGK'S ONE GLOBAL. It is set to HIS voxel so the two
        // systems discretise at the same pitch and the file-size comparison is
        // like for like.
        float fVoxelSize = fVoxelArg > 0 ? fVoxelArg : xField.H;
        var swAll = Stopwatch.StartNew();
        using var lib = new Library(fVoxelSize);
        W($"PicoGK        {Library.strName()} {Library.strVersion()}");
        W($"voxel size    {fVoxelSize:F9} mm  ({(fVoxelArg > 0 ? "lattice pitch" : "HIS DESIGN voxel — too coarse for struts")})");
        W($"              min strut 0.45 mm = {0.45f / fVoxelSize:F2} voxels across");
        W("");

        long rss0 = Environment.WorkingSet;

        var swStep = Stopwatch.StartNew();
        Mesh mshBounding = Mesh.mshFromStlFile(stlPath, Mesh.EStlUnit.MM, 1.0f, null, lib);
        Voxels voxBounding = new Voxels(mshBounding);
        double tBound = swStep.Elapsed.TotalSeconds;
        voxBounding.CalculateProperties(out float fVolBounding, out BBox3 oBox);
        W($"bounding      {mshBounding.nTriangleCount():N0} triangles in, "
          + $"{fVolBounding:N0} mm3, bbox {oBox.vecMin} .. {oBox.vecMax}   [{tBound:F1} s]");

        swStep.Restart();
        xField.Build(lib);
        double tField = swStep.Elapsed.TotalSeconds;
        xField.Field.GetVoxelDimensions(out int fx, out int fy, out int fz);
        W($"ScalarField   {fx} x {fy} x {fz} active voxels   [{tField:F1} s]");
        W("");

        // ── the lattice, LatticeLibrary's own four-step recipe ────────────────
        ICellArray xCells = new RegularCellArray(voxBounding, fCellMM, fCellMM, fCellMM, 0f);
        ILatticeType xType = new BodyCentreLattice();
        var xThick = new FieldBeamThickness(xField, 0.45f, 2.4f, fDriverMax); // his min extrudable width .. 2.4 mm
        xThick.SetBoundingVoxels(voxBounding);
        int nCells = xCells.aGetUnitCells().Count;
        W($"cells         {nCells:N0} unit cells of {fCellMM:F2} mm");

        swStep.Restart();
        Voxels voxLattice = voxGetFinalLatticeGeometry(lib, xCells, xType, xThick, 5);
        double tLattice = swStep.Elapsed.TotalSeconds;
        W($"lattice       generated in {tLattice:F1} s, "
          + $"{xThick.Samples:N0} thickness lookups, "
          + $"rho seen [{xThick.MinSeen:F4}, {xThick.MaxSeen:F4}]");

        swStep.Restart();
        voxLattice &= voxBounding;
        double tClip = swStep.Elapsed.TotalSeconds;
        voxLattice.CalculateProperties(out float fVolLattice, out BBox3 _);
        W($"clipped       to the design in {tClip:F1} s, {fVolLattice:N0} mm3 "
          + $"({100.0 * fVolLattice / fVolBounding:F2}% of the design)");
        W("");

        long rssPeak = Environment.WorkingSet;
        W($"MEMORY        managed working set {rssPeak / 1024 / 1024:N0} MB "
          + $"(was {rss0 / 1024 / 1024:N0} MB before any geometry)");

        // ── what it writes ────────────────────────────────────────────────────
        swStep.Restart();
        Mesh mshLattice = new Mesh(voxLattice);
        double tMesh = swStep.Elapsed.TotalSeconds;
        string stlOut = Path.Combine(outDir, "lattice.stl");
        mshLattice.SaveToStlFile(stlOut);
        long stlBytes = new FileInfo(stlOut).Length;
        W($"MESH          {mshLattice.nTriangleCount():N0} triangles in {tMesh:F1} s");
        W($"STL           {stlBytes:N0} bytes ({stlBytes / 1024.0 / 1024.0:F1} MB)");

        // The implicit form: PicoGK's own VDB serialisation, which is what an
        // implicit pipeline would actually keep.
        string vdbOut = Path.Combine(outDir, "lattice.vdb");
        voxLattice.SaveToVdbFile(vdbOut);
        long vdbBytes = new FileInfo(vdbOut).Length;
        W($"VDB           {vdbBytes:N0} bytes ({vdbBytes / 1024.0 / 1024.0:F1} MB) — "
          + $"{(double)stlBytes / vdbBytes:F1}x smaller than the STL");
        W("");
        W($"TOTAL WALL    {swAll.Elapsed.TotalSeconds:F1} s");

        // ── (b) IS THE GRADING CONTINUOUS? ────────────────────────────────────
        // Sampled along a line through the part: the thickness the lattice was
        // asked for at successive points, and the biggest STEP between adjacent
        // samples. A cell-quantised grading shows a staircase here; a continuous
        // one does not.
        W("");
        W("── (b) IS THE THICKNESS CONTINUOUS? ─────────────────────────────────");
        using (var csv = new StreamWriter(Path.Combine(outDir, "grading_profile.csv")))
        {
            csv.WriteLine("axis,s_mm,rho,thickness_mm");
            foreach (var (name, a, b) in new (string, Vector3, Vector3)[]
            {
                ("x", new Vector3(oBox.vecMin.X, (oBox.vecMin.Y + oBox.vecMax.Y) / 2, (oBox.vecMin.Z + oBox.vecMax.Z) / 2),
                      new Vector3(oBox.vecMax.X, (oBox.vecMin.Y + oBox.vecMax.Y) / 2, (oBox.vecMin.Z + oBox.vecMax.Z) / 2)),
                ("z", new Vector3((oBox.vecMin.X + oBox.vecMax.X) / 2, (oBox.vecMin.Y + oBox.vecMax.Y) / 2, oBox.vecMin.Z),
                      new Vector3((oBox.vecMin.X + oBox.vecMax.X) / 2, (oBox.vecMin.Y + oBox.vecMax.Y) / 2, oBox.vecMax.Z)),
            })
            {
                int N = 2000; double maxStep = 0; double prev = double.NaN;
                for (int s = 0; s <= N; s++)
                {
                    Vector3 p = Vector3.Lerp(a, b, (float)s / N);
                    double rho = Math.Clamp(xField.Sample(p), 0, 1);
                    double t = xThick.fGetBeamThickness(p);
                    csv.WriteLine($"{name},{Vector3.Distance(a, p):F6},{rho:F6},{t:F6}");
                    if (!double.IsNaN(prev)) maxStep = Math.Max(maxStep, Math.Abs(t - prev));
                    prev = t;
                }
                double sampleSpacing = Vector3.Distance(a, b) / N;
                W($"  along {name}: {N} samples {sampleSpacing:F4} mm apart, "
                  + $"largest adjacent thickness STEP {maxStep:F6} mm "
                  + $"({100 * maxStep / (2.4 - 0.45):F3}% of the full thickness range)");
            }
        }
        Report(Path.Combine(outDir, "s3_report.txt"), sw.ToString());
    }
}
