// WPF printing (Wine Mono sg40, test/wpf-print-test.sh): PrintDialog.PrintVisual/PrintDocument and
// XpsDocumentWriter print through the printer's GDI driver (System.Printing's NGC path); XPS files.
using System; using System.IO; using System.Linq; using System.Printing; using System.Windows;
using System.Windows.Controls; using System.Windows.Documents; using System.Windows.Markup;
using System.Windows.Media; using System.Windows.Shapes; using System.Windows.Threading;
using System.Windows.Xps; using System.Windows.Xps.Packaging;
class P {
  // a 2 x 2 inch blue square 2 inches from the paper's corner, and a line of text
  static FrameworkElement Square() {
    var c = new Canvas { Width = 816, Height = 1056 };
    var r = new Rectangle { Width = 192, Height = 192, Fill = Brushes.Blue };
    Canvas.SetLeft(r, 192); Canvas.SetTop(r, 192); c.Children.Add(r);
    var t = new TextBlock { Text = "Stained Glass WPF print", FontSize = 24 };
    Canvas.SetLeft(t, 192); Canvas.SetTop(t, 96); c.Children.Add(t);
    c.Measure(new Size(816, 1056)); c.Arrange(new Rect(0, 0, 816, 1056)); c.UpdateLayout();
    return c;
  }
  static FixedDocument Fixed(int n) {
    var doc = new FixedDocument();
    for (int i = 0; i < n; i++) {
      var page = new FixedPage { Width = 816, Height = 1056 };
      var r = new Rectangle { Width = 192, Height = 192, Fill = Brushes.Blue };
      FixedPage.SetLeft(r, 192); FixedPage.SetTop(r, 192); page.Children.Add(r);
      var t = new TextBlock { Text = "Fixed page " + (i + 1), FontSize = 24 };
      FixedPage.SetLeft(t, 192); FixedPage.SetTop(t, 96); page.Children.Add(t);
      var pc = new PageContent(); ((IAddChild)pc).AddChild(page); doc.Pages.Add(pc);
    }
    return doc;
  }
  [STAThread] static void Main(string[] a) {
    string what = a[0];
    try {
      var queue = new LocalPrintServer().GetPrintQueue(a[1]);
      queue.CurrentJobSettings.Description = "sg40 " + what;
      if (what == "visual") {
        var pd = new PrintDialog { PrintQueue = queue };
        pd.PrintVisual(Square(), "sg40 visual");
        Console.WriteLine("visual=ok");
      } else if (what == "writer") {
        var w = PrintQueue.CreateXpsDocumentWriter(queue);
        string tickets = "";
        w.WritingPrintTicketRequired += (s, e) => tickets += e.CurrentPrintTicketLevel.ToString().Replace("PrintTicket", "") + e.Sequence + " ";
        w.Write(Square());
        Console.WriteLine("writer=ok " + tickets.Trim());
      } else if (what == "flow") {
        var doc = new FlowDocument { PageWidth = 816, PageHeight = 1056, ColumnWidth = 700 };
        for (int i = 0; i < 90; i++) doc.Blocks.Add(new Paragraph(new Run("Paragraph " + (i + 1) + " of a FlowDocument.")));
        new PrintDialog { PrintQueue = queue }.PrintDocument(((IDocumentPaginatorSource)doc).DocumentPaginator, "sg40 flow");
        Console.WriteLine("flow=ok");
      } else if (what == "fixed") {
        PrintQueue.CreateXpsDocumentWriter(queue).Write(Fixed(3));
        Console.WriteLine("fixed=ok");
      } else if (what == "collator") {
        var c = PrintQueue.CreateXpsDocumentWriter(queue).CreateVisualsCollator();
        c.BeginBatchWrite(); c.Write(Square()); c.Write(Square()); c.EndBatchWrite();
        Console.WriteLine("collator=ok");
      } else if (what == "async") {
        var w = PrintQueue.CreateXpsDocumentWriter(queue);
        int progress = 0;
        w.WritingProgressChanged += (s, e) => progress++;
        w.WritingCompleted += (s, e) => {
          Console.WriteLine("async=" + (e.Error == null && !e.Cancelled ? "ok" : "error " + e.Error) + " " + e.UserState + " " + (progress > 0 ? "progress" : "noprogress"));
          Dispatcher.CurrentDispatcher.InvokeShutdown();
        };
        w.WriteAsync(Fixed(2), "state");
        Dispatcher.Run();
      } else if (what == "xps") {
        string path = a[2];
        using (var xd = new XpsDocument(path, FileAccess.ReadWrite)) XpsDocument.CreateXpsDocumentWriter(xd).Write(Fixed(2));
        using (var xd = new XpsDocument(path, FileAccess.Read))
          Console.WriteLine("xpsfile=" + xd.GetFixedDocumentSequence().DocumentPaginator.PageCount);
        PrintQueue.CreateXpsDocumentWriter(queue).Write(path);
        Console.WriteLine("xps=ok");
        GC.Collect(); GC.WaitForPendingFinalizers();
      }
    } catch (Exception e) { Console.WriteLine(what + "=" + e.GetType().Name + ": " + e.Message); if (Environment.GetEnvironmentVariable("SG40_TRACE") != null) Console.WriteLine(e); }
  }
}
