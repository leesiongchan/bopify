# Bopify product page

Static HTML and CSS with a continuously spinning record that respects reduced-motion preferences. No JavaScript, install or build is required.

Preview from the repository root:

```sh
python3 -m http.server 4187 --bind 127.0.0.1
```

Open `http://127.0.0.1:4187/site/`. Relative URLs also support the GitHub Pages project path.

In the repository's **Settings → Pages → Build and deployment**, select **GitHub Actions**.
The `Product page` workflow deploys changes to `site/` on `main`, or can be run manually.
The expected public address is `https://leesiongchan.github.io/bopify/`.
The workflow publishes only the HTML, CSS and assets; this README is excluded.

Download links use GitHub's latest release page so a new app release needs no website edit.
The screenshot and icon are copied from the app; refresh these assets when the app's appearance changes.
