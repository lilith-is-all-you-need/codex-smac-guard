using System; using System.IO; using System.Text;
public class FakeCodex { public static int Main(string[] a){
  Console.InputEncoding = new UTF8Encoding(false);
  Console.OutputEncoding = new UTF8Encoding(false);
  var dir = AppContext.BaseDirectory;
  var f = Path.Combine(dir, "count.txt");
  int n = File.Exists(f)? int.Parse(File.ReadAllText(f).Trim()):0;
  n++; File.WriteAllText(f, n.ToString());
  var inp = Console.In.ReadToEnd();
  if(n<=5){ Console.WriteLine("ERROR: Selected model is at capacity. Please try a different model."); return 1; }
  Console.WriteLine("PONG len="+inp.Length); return 0;
}}
