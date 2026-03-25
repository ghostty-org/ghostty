using Microsoft.UI.Xaml.Navigation;
using Microsoft.UI.Windowing;
using Windows.Graphics;

namespace Ghostty;

public partial class App : Application
{
    private Window? _window;

    public App()
    {
        this.InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs e)
    {
        _window ??= new Window
        {
            Title = "Ghostty"
        };

        if (_window.Content is not Frame rootFrame)
        {
            rootFrame = new Frame();
            rootFrame.NavigationFailed += OnNavigationFailed;
            _window.Content = rootFrame;
        }

        rootFrame.Navigate(typeof(Views.MainPage), e.Arguments);

        // Resize to fit the 800x600 image
        var appWindow = _window.AppWindow;
        appWindow.Resize(new SizeInt32(816, 639));

        _window.Activate();
    }

    private void OnNavigationFailed(object sender, NavigationFailedEventArgs e)
    {
        throw new InvalidOperationException($"Failed to load page {e.SourcePageType.FullName}");
    }
}
