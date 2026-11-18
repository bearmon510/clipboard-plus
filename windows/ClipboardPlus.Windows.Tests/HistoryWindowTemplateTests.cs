using System.Windows;
using ClipboardPlus.Sync;
using ClipboardPlus.Windows.Core;
using Xunit;
using DataFormats = System.Windows.DataFormats;

namespace ClipboardPlus.Windows.Tests;

public sealed class HistoryWindowTemplateTests
{
    private static void RunSta(Action action)
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try { action(); }
            catch (Exception ex) { failure = ex; }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        if (failure is not null)
            System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(failure).Throw();
    }

    [Fact]
    public void BuildTextDragDataObjectSetsSelfMarkerAndUnicodeText()
    {
        RunSta(() =>
        {
            var data = HistoryWindow.BuildTextDragDataObject("ドラッグする定型文");

            Assert.True(data.GetDataPresent(HistoryWindow.SelfDragFormat));
            Assert.True(data.GetDataPresent(DataFormats.UnicodeText));
            Assert.Equal("ドラッグする定型文", data.GetText());
            Assert.Equal(DropSourceKind.None, HistoryWindow.DetectDropSource(data, isDraggingFromSelf: false));
        });
    }

    [Fact]
    public void TemplateRowsFormatTitlesLinksColorsAndMoveCapabilities()
    {
        RunSta(() =>
        {
            var headerTagged = new TemplateHeaderRow(new TemplateGroupView("仕事", "仕事", []), isExpanded: true);
            Assert.True(headerTagged.IsHeader);
            Assert.False(headerTagged.IsUntagged);
            Assert.Equal("仕事", headerTagged.Title);
            Assert.Equal("0", headerTagged.Count);
            Assert.Equal("\uE70D", headerTagged.ChevronGlyph);

            var headerUntagged = new TemplateHeaderRow(new TemplateGroupView(null, "その他", []), isExpanded: false);
            Assert.True(headerUntagged.IsUntagged);
            Assert.Equal("その他", headerUntagged.Title);
            Assert.Equal("\uE76C", headerUntagged.ChevronGlyph);

            var group = new TemplateGroupView("仕事", "仕事", []);
            var linkItem = new TemplateSyncItem(Guid.NewGuid(), TemplateSyncKind.Url, "https://example.com/a/b", "リンク名", "仕事", 0, 100);
            var linkRow = new TemplateCardRow(new TemplateListEntry(false, group, linkItem, true, 0, 2));
            Assert.False(linkRow.IsHeader);
            Assert.Equal("リンク名", linkRow.Name);
            Assert.Equal(Visibility.Visible, linkRow.NameVisibility);
            Assert.Equal(HistoryDisplayFlavor.Link, linkRow.Flavor);
            Assert.Equal("example.com", linkRow.LinkHost);
            Assert.Equal("/a/b", linkRow.LinkRemainder);
            Assert.Equal(Visibility.Visible, linkRow.LinkVisibility);
            Assert.Equal(Visibility.Collapsed, linkRow.PlainTextVisibility);
            Assert.False(linkRow.CanMoveUp);
            Assert.True(linkRow.CanMoveDown);

            var colorItem = new TemplateSyncItem(Guid.NewGuid(), TemplateSyncKind.Text, "#2663EB", null, "仕事", 1, 101);
            var colorRow = new TemplateCardRow(new TemplateListEntry(false, group, colorItem, true, 1, 2));
            Assert.Equal(Visibility.Collapsed, colorRow.NameVisibility);
            Assert.Equal(HistoryDisplayFlavor.Color, colorRow.Flavor);
            Assert.Equal(Visibility.Visible, colorRow.ColorSwatchVisibility);
            Assert.NotNull(colorRow.SwatchBrush);
            Assert.Equal(Visibility.Visible, colorRow.PlainTextVisibility);
            Assert.True(colorRow.CanMoveUp);
            Assert.False(colorRow.CanMoveDown);
        });
    }
}
