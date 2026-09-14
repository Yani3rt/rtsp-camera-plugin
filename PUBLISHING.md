# Publish RTSP Camera

This repository contains the root manifest, MIT license and upstream attribution,
installation/removal instructions, bundled shader, and `preview.png` expected by
the [publishing guide](https://plugins.omarchy.org/publish.html).

Before submitting:

1. Review the MIT license and the ownership statements in the submission draft.
2. Commit and push the prepared files to `main`.
3. Make `Yani3rt/rtsp-camera-plugin` public in GitHub repository settings. Review
   the files and commit history before changing visibility: public visibility
   exposes the repository's history as well as the latest files.
4. Run `omarchy plugin validate .`, the Python tests, and the QML checks described
   in the README. Check that `yani.camera` remains available in the marketplace;
   plugin IDs are permanent.
5. Open the [submission form](https://github.com/omacom/omarchy-plugin-marketplace/issues/new?template=submit-plugin.yml).
   Use the title **[Plugin]: RTSP Camera** and the fields in
   [docs/marketplace-submission.md](docs/marketplace-submission.md). Review and
   check all five statements only when they are true.

Category: **Widgets**. Tags: **bar**, **media**, **quickshell**.
The preview shows the actual plugin with generated video, without private footage.
No install script or extra setup script is required; users configure their camera
through the plugin after installation.

The marketplace validates the submitted commit and runs its automated security
baseline. Listing still requires a maintainer's approval; local checks do not
grant marketplace approval. Follow the feedback on the original submission issue
instead of opening duplicates. See the marketplace's
[submission instructions](https://github.com/omacom/omarchy-plugin-marketplace/blob/main/SUBMISSION.md).
