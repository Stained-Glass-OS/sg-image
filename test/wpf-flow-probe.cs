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

                {
                    var heb = new TextBlock { Text = "\u05e9\u05dc\u05d5\u05dd", FlowDirection = FlowDirection.RightToLeft, Width = 300, FontSize = 20 };
                    heb.Measure(new Size(300, 50)); heb.Arrange(new Rect(0, 0, 300, 50));
                    var bmpH = new RenderTargetBitmap(300, 50, 96, 96, PixelFormats.Pbgra32); bmpH.Render(heb);
                    byte[] ph = new byte[300 * 4 * 50]; bmpH.CopyPixels(ph, 300 * 4, 0);
                    int hl = 0, hr = 0;
                    for (int y = 0; y < 50; y++) for (int x = 0; x < 300; x++) if (ph[(y * 300 + x) * 4 + 3] > 128) { if (x < 150) hl++; else hr++; }
                    Console.WriteLine("RTLHEBREW left " + hl + " right " + hr);
                    { var enc = new PngBitmapEncoder(); enc.Frames.Add(BitmapFrame.Create(bmpH)); using (var fs = File.Create(Path.Combine(outDir, "heb.png"))) enc.Save(fs); }
                    var rtl = new TextBlock { Text = "Hello", FlowDirection = FlowDirection.RightToLeft, Width = 300, FontSize = 20 };
                    rtl.Measure(new Size(300, 50)); rtl.Arrange(new Rect(0, 0, 300, 50));
                    var bmpR = new RenderTargetBitmap(300, 50, 96, 96, PixelFormats.Pbgra32); bmpR.Render(rtl);
                    byte[] pr = new byte[300 * 4 * 50]; bmpR.CopyPixels(pr, 300 * 4, 0);
                    int left = 0, right = 0;
                    for (int y = 0; y < 50; y++) for (int x = 0; x < 300; x++) if (pr[(y * 300 + x) * 4 + 3] > 128) { if (x < 150) left++; else right++; }
                    Console.WriteLine("RTLTEXTBLOCK left " + left + " right " + right);
                }
                var ft = new FormattedText("Centred", System.Globalization.CultureInfo.InvariantCulture, FlowDirection.LeftToRight, new Typeface("Arial"), 14, Brushes.Black, 1.0);
                ft.MaxTextWidth = 300; ft.TextAlignment = TextAlignment.Center;
                Console.WriteLine("FORMATTEDTEXT boundsX " + ft.BuildHighlightGeometry(new Point(0, 0)).Bounds.X.ToString("F1") + " width " + ft.Width.ToString("F1") + " widthWS " + ft.WidthIncludingTrailingWhitespace.ToString("F1"));
                var centred = (Paragraph)tail.PreviousBlock.PreviousBlock;
                Console.WriteLine("FLOW centredX " + centred.ContentStart.GetCharacterRect(LogicalDirection.Forward).X.ToString("F1") + " rtlX " + ((Paragraph)tail.PreviousBlock).ContentStart.GetCharacterRect(LogicalDirection.Forward).X.ToString("F1"));

                // tables: three rows, a cell spanning two, borders; and a long one over pages
                var doc4 = new FlowDocument { PagePadding = new Thickness(10), FontFamily = new FontFamily("Arial"), FontSize = 14 };
                var t4 = new Table { CellSpacing = 4, BorderBrush = Brushes.Black, BorderThickness = new Thickness(1) };
                t4.Columns.Add(new TableColumn()); t4.Columns.Add(new TableColumn());
                var g4 = new TableRowGroup();
                TableCell[,] c4 = new TableCell[3, 2];
                for (int r = 0; r < 3; r++)
                {
                    var tr = new TableRow();
                    for (int k = 0; k < 2; k++)
                    {
                        if (r == 1 && k == 0) continue;     // covered by the spanning cell
                        var cell = new TableCell(new Paragraph(new Run("r" + r + "c" + k))) { BorderBrush = Brushes.Gray, BorderThickness = new Thickness(1) };
                        if (r == 0 && k == 0) { cell.RowSpan = 2; ((Paragraph)cell.Blocks.FirstBlock).Inlines.Add(new LineBreak()); ((Paragraph)cell.Blocks.FirstBlock).Inlines.Add(new Run("two")); ((Paragraph)cell.Blocks.FirstBlock).Inlines.Add(new LineBreak()); ((Paragraph)cell.Blocks.FirstBlock).Inlines.Add(new Run("rows")); }
                        c4[r, k] = cell;
                        tr.Cells.Add(cell);
                    }
                    g4.Rows.Add(tr);
                }
                t4.RowGroups.Add(g4);
                doc4.Blocks.Add(t4);
                var after4 = new Paragraph(new Run("After the table."));
                doc4.Blocks.Add(after4);
                rtb.Document = doc4;
                w.UpdateLayout();
                Func<TableCell, Rect> cr = cc => cc.ContentStart.GetCharacterRect(LogicalDirection.Forward);
                Console.WriteLine("TABLE r0c0 " + cr(c4[0, 0]).Y.ToString("F1") + " r0c1 " + cr(c4[0, 1]).Y.ToString("F1") + " r1c1 " + cr(c4[1, 1]).Y.ToString("F1")
                    + " r2c0 " + cr(c4[2, 0]).Y.ToString("F1") + " c1x " + cr(c4[0, 1]).X.ToString("F1") + " after " + Top(after4).ToString("F1"));
                Save(w, (int)w.ActualWidth, (int)w.ActualHeight, "table.png");

                var doc5 = new FlowDocument { PagePadding = new Thickness(10), FontFamily = new FontFamily("Arial"), FontSize = 14 };
                var t5 = new Table();
                t5.Columns.Add(new TableColumn()); t5.Columns.Add(new TableColumn());
                var g5 = new TableRowGroup();
                for (int r = 0; r < 40; r++)
                {
                    var tr = new TableRow();
                    tr.Cells.Add(new TableCell(new Paragraph(new Run("row " + r))));
                    tr.Cells.Add(new TableCell(new Paragraph(new Run("value " + r))));
                    g5.Rows.Add(tr);
                }
                t5.RowGroups.Add(g5);
                doc5.Blocks.Add(t5);
                var pag5 = ((IDocumentPaginatorSource)doc5).DocumentPaginator;
                pag5.PageSize = new Size(300, 200);
                pag5.ComputePageCount();
                Console.WriteLine("TABLEPAGES " + pag5.PageCount);
                Save(pag5.GetPage(1).Visual, 300, 200, "tablepage1.png");

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
