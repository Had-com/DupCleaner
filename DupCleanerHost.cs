// DupCleaner launcher: runs the embedded script inside this process (no .ps1 file, no console window).
using System;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using System.Management.Automation;
using System.Management.Automation.Runspaces;

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        string script;
        using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("DupCleaner.ps1"))
        using (StreamReader r = new StreamReader(s, Encoding.UTF8)) script = r.ReadToEnd();
        try
        {
            InitialSessionState iss = InitialSessionState.CreateDefault();
            iss.ApartmentState = ApartmentState.STA;
            iss.ThreadOptions = PSThreadOptions.UseCurrentThread;
            using (Runspace rs = RunspaceFactory.CreateRunspace(iss))
            {
                rs.Open();
                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = rs;
                    ps.AddScript(script, false);
                    ps.Invoke();
                    if (ps.Streams.Error.Count > 0)
                    {
                        string first = ps.Streams.Error[0].ToString();
                        // the script has its own crash log; only a startup failure ends up here
                        if (first.Length > 0 && !ps.HadErrors) MessageBox.Show(first, "DupCleaner");
                    }
                }
            }
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show("DupCleaner could not start:\n\n" + ex.Message, "DupCleaner", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
