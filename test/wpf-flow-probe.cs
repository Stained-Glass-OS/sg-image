// wpf-flow-probe: WPF's flow layout (PTS) under our Wine Mono -- a
// RichTextBox (bottomless page), an edit (update), a paginated FlowDocument
// (finite pages), lists, sections, BlockUIContainer, inline controls,
// alignment. Prints what it measured (test/wpf-flow-test.sh reads it) and
// writes PNGs of the window and a page.
// SPDX-License-Identifier: AGPL-3.0-or-later
using System;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

class Probe
{
    static string outDir = ".";
    static FlowDocument MakeDoc(int paragraphs)
    {
        var doc = new FlowDocument();
        doc.PagePadding = new Thickness(10);
        doc.FontFamily = new FontFamily("Arial");
        doc.FontSize = 14;
        for (int i = 0; i < paragraphs; i++)
            doc.Blocks.Add(new Paragraph(new Run("Paragraph " + i + ": the quick brown fox jumps over the lazy dog, again and again, so that this line has to wrap at least once in a narrow window.")));
        var list = new List();
        list.ListItems.Add(new ListItem(new Paragraph(new Run("first item"))));
        list.ListItems.Add(new ListItem(new Paragraph(new Run("second item"))));
        doc.Blocks.Add(list);
        var sec = new Section(new Paragraph(new Bold(new Run("inside a section"))));
        sec.Background = Brushes.LightYellow;
        sec.Margin = new Thickness(20, 6, 0, 6);
        doc.Blocks.Add(sec);
        doc.Blocks.Add(new BlockUIContainer(new Button { Content = "A button", Width = 120, Height = 30 }));
        doc.Blocks.Add(new Paragraph(new Run("Last paragraph.")));
        return doc;
    }

    static double Top(TextElement e)
    {
        return e.ContentStart.GetCharacterRect(LogicalDirection.Forward).Top;
    }

    static void Save(Visual v, int w, int h, string name)
    {
        var bmp = new RenderTargetBitmap(w, h, 96, 96, PixelFormats.Pbgra32);
        bmp.Render(v);
        var enc = new PngBitmapEncoder();
        enc.Frames.Add(BitmapFrame.Create(bmp));
        using (var f = File.Create(Path.Combine(outDir, name))) enc.Save(f);
    }

    [STAThread]
    static int Main(string[] args)
    {
        if (args.Length > 0) outDir = args[0];
        int rc = 0;
        var app = new Application();
        var w = new Window { Width = 420, Height = 600, Title = "ptsprobe" };
        var doc = MakeDoc(3);
        var rtb = new RichTextBox(doc);
        w.Content = rtb;
        w.Loaded += (s, e) => w.Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, (Action)(() =>
        {
            try
            {
                double last = -1;
                bool ordered = true;
                foreach (Block b in doc.Blocks)
                {
                    double y = b is BlockUIContainer ? ((BlockUIContainer)b).Child.TranslatePoint(new Point(0, 0), rtb).Y : Top(b);
                    Console.WriteLine("block " + b.GetType().Name + " top " + y.ToString("F1"));
                    if (!(y > last)) ordered = false;
                    last = y;
                }
                var p0 = (Paragraph)doc.Blocks.FirstBlock;
                double h0 = p0.ContentEnd.GetCharacterRect(LogicalDirection.Backward).Bottom - Top(p0);
                Console.WriteLine("BOTTOMLESS " + (ordered ? "ordered" : "NOT-ordered") + " firstParaHeight " + h0.ToString("F1"));
                Save(w, (int)w.ActualWidth, (int)w.ActualHeight, "window.png");

                // the list's bullets: dark pixels just left of the first item's text
                var item = (Paragraph)((List)p0.NextBlock.NextBlock.NextBlock).ListItems.FirstListItem.Blocks.FirstBlock;
                Rect ir = item.ContentStart.GetCharacterRect(LogicalDirection.Forward);
                Point ip = rtb.TranslatePoint(new Point(ir.X, ir.Y), w);
                var bmp = new RenderTargetBitmap((int)w.ActualWidth, (int)w.ActualHeight, 96, 96, PixelFormats.Pbgra32);
                bmp.Render(w);
                int stride = bmp.PixelWidth * 4;
                byte[] px = new byte[stride * bmp.PixelHeight];
                bmp.CopyPixels(px, stride, 0);
                int dark = 0;
                for (int y = (int)ip.Y; y < (int)(ip.Y + ir.Height) && y < bmp.PixelHeight; y++)
                    for (int x = Math.Max(0, (int)ip.X - 20); x < (int)ip.X - 2; x++)
                    {
                        int o = y * stride + x * 4;
                        if (px[o] + px[o + 1] + px[o + 2] < 300) dark++;
                    }
                Console.WriteLine("BULLETS dark " + dark);

                // an edit: a new paragraph at the start; the old first one moves down
                double before = Top(p0);
                doc.Blocks.InsertBefore(p0, new Paragraph(new Run("Inserted at the start.")));
                w.UpdateLayout();
                double after = Top(p0);
                Console.WriteLine("UPDATE moved " + (after - before).ToString("F1"));

                // paginated: small pages
                var doc2 = MakeDoc(12);
                var pag = ((IDocumentPaginatorSource)doc2).DocumentPaginator;
                pag.PageSize = new Size(300, 200);
                pag.ComputePageCount();
                Console.WriteLine("PAGES " + pag.PageCount);
                var page = pag.GetPage(1);
                Save(page.Visual, 300, 200, "page1.png");

                // everything else a document may hold: no exceptions, and the last paragraph below the rest
                var doc3 = MakeDoc(1);
                var table = new Table();
                table.Columns.Add(new TableColumn());
                table.Columns.Add(new TableColumn());
                var rg = new TableRowGroup();
                var row = new TableRow();
                row.Cells.Add(new TableCell(new Paragraph(new Run("cell A"))));
                row.Cells.Add(new TableCell(new Paragraph(new Run("cell B"))));
                rg.Rows.Add(row);
                table.RowGroups.Add(rg);
                doc3.Blocks.Add(table);
                var rich = new Paragraph();
                rich.Inlines.Add(new Run("A link: "));
                rich.Inlines.Add(new Hyperlink(new Run("example")));
                rich.Inlines.Add(new Run(" an inline control: "));
                rich.Inlines.Add(new InlineUIContainer(new CheckBox { Content = "check" }));
                rich.Inlines.Add(new Floater(new Paragraph(new Run("a floater"))) { Width = 80 });
                rich.Inlines.Add(new Figure(new Paragraph(new Run("a figure"))));
                rich.Inlines.Add(new Run(" and more text after them."));
                doc3.Blocks.Add(rich);
                var fl = new Paragraph(new Run("Before"));
                fl.Inlines.Add(new Floater(new Paragraph(new Run("F"))) { Width = 50 });
                fl.Inlines.Add(new Run(" after floater"));
                doc3.Blocks.Add(fl);
                var fg = new Paragraph(new Run("Before"));
                fg.Inlines.Add(new Figure(new Paragraph(new Run("G"))));
                fg.Inlines.Add(new Run(" after figure"));
                doc3.Blocks.Add(fg);
                doc3.Blocks.Add(new Paragraph(new Run("Centred.")) { TextAlignment = TextAlignment.Center });
                doc3.Blocks.Add(new Paragraph(new Run("Right to left.")) { FlowDirection = FlowDirection.RightToLeft });
                var tail = new Paragraph(new Run("The end."));
                doc3.Blocks.Add(tail);
                rtb.Document = doc3;
                w.UpdateLayout();
                Console.WriteLine("MIXED tailTop " + Top(tail).ToString("F1") + " richTop " + Top(rich).ToString("F1"));
                var check = (CheckBox)((InlineUIContainer)rich.Inlines.FirstInline.NextInline.NextInline.NextInline).Child;
                Console.WriteLine("INLINE checkX " + check.TranslatePoint(new Point(0, 0), rtb).X.ToString("F1"));
                Save(w, (int)w.ActualWidth, (int)w.ActualHeight, "mixed.png");

                var ft = new FormattedText("Centred", System.Globalization.CultureInfo.InvariantCulture, FlowDirection.LeftToRight, new Typeface("Arial"), 14, Brushes.Black, 1.0);
                ft.MaxTextWidth = 300; ft.TextAlignment = TextAlignment.Center;
                Console.WriteLine("FORMATTEDTEXT boundsX " + ft.BuildHighlightGeometry(new Point(0, 0)).Bounds.X.ToString("F1") + " width " + ft.Width.ToString("F1") + " widthWS " + ft.WidthIncludingTrailingWhitespace.ToString("F1"));
                var centred = (Paragraph)tail.PreviousBlock.PreviousBlock;
                Console.WriteLine("FLOW centredX " + centred.ContentStart.GetCharacterRect(LogicalDirection.Forward).X.ToString("F1") + " rtlX " + ((Paragraph)tail.PreviousBlock).ContentStart.GetCharacterRect(LogicalDirection.Forward).X.ToString("F1"));

                // a long document
                var sw = System.Diagnostics.Stopwatch.StartNew();
                rtb.Document = MakeDoc(500);
                w.UpdateLayout();
                Console.WriteLine("LONG ms " + sw.ElapsedMilliseconds + " extent " + rtb.ExtentHeight.ToString("F0"));
            }
            catch (Exception ex)
            {
                Console.WriteLine("EXCEPTION " + ex);
                rc = 1;
            }
            w.Close();
        }));
        app.Run(w);
        return rc;
    }
}
