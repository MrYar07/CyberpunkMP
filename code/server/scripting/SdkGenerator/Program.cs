using CppSharp;
using CppSharp.AST;
using CppSharp.Generators;
using System.Runtime.InteropServices;

internal class CyberpunkSdk : ILibrary
{
    private string Module { get; set; }
    private string OutputPath { get; set; }
    private string SourcePath { get; set; }
    private string[] FileNames { get; set; }

    internal CyberpunkSdk(string module, string outputPath, string sourcePath, string[] fileNames)
    {
        Module = module;
        OutputPath = outputPath;
        SourcePath = sourcePath;
        FileNames = fileNames;
    }

    public void Postprocess(Driver driver, ASTContext ctx)
    {
    }

    public void Preprocess(Driver driver, ASTContext ctx)
    {
    }

    public void Setup(Driver driver)
    {
        var options = driver.Options;
        options.OutputDir = OutputPath;
        options.GeneratorKind = GeneratorKind.CSharp;

        var parserOptions = driver.ParserOptions;
        parserOptions.AddDefines("WIN32");
        parserOptions.AddDefines("CPPSHARP_GENERATOR");

        var module = options.AddModule(Module);
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            module.SharedLibraryName = "Server.Native.dll";
        else
            module.SharedLibraryName = "Server.Native";

        module.IncludeDirs.Add(SourcePath);

        foreach (var file in FileNames)
        {
            module.Headers.Add(file);
        }
    }

    public void SetupPasses(Driver driver)
    {

    }
}

internal class Program
{
    private static string GetGitRoot()
    {
        // Walk up to the directory holding .git. In a git worktree .git is a file pointing at
        // the main checkout, and Repository.Discover would resolve to that other checkout.
        var directory = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (directory != null)
        {
            string dotGit = Path.Combine(directory.FullName, ".git");
            if (Directory.Exists(dotGit) || File.Exists(dotGit))
                return directory.FullName + Path.DirectorySeparatorChar;

            directory = directory.Parent;
        }

        throw new Exception("This code should be ran from a Git repository!");
    }

    private static void Main(string[] args)
    {
        var fileNames = args.Select(arg => Path.GetFileName(arg)).ToArray();

        try
        {
            string root = GetGitRoot();
            string output = Path.Combine(root, @"code/server/scripting/CyberpunkSdk");
            string outputLoader = Path.Combine(root, @"code/server/loader");
            string source = Path.Combine(root, @"code/server/native/Scripting");

            ConsoleDriver.Run(new CyberpunkSdk("CyberpunkSdk.Internal", output, source, fileNames));
            ConsoleDriver.Run(new CyberpunkSdk("CyberpunkMp", outputLoader, source, new[] { "ServerAPI.h" }));

            //string sdkFile = Path.Combine(output, "CyberpunkSdk.Internal.cs");

            //string text = File.ReadAllText(sdkFile);

            /*if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
                text = text.Replace("Server.exe.dll", "Server.exe");
            else
                text = text.Replace("DllImport(\"Server\"", "DllImport(\"../Server\"");*/
           
            //File.WriteAllText(sdkFile, text);
        }
        catch(Exception e)
        {
            Console.WriteLine(e);
        }
    }
}