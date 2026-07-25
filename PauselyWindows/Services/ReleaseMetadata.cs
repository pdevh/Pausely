using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace PauselyWindows.Services
{
    internal sealed record ReleaseAssetMetadata(
        string Name,
        Uri DownloadUri,
        long Size,
        string Digest);

    internal sealed record ReleaseMetadata(
        Version Version,
        string VersionText,
        string ReleaseNotes,
        ReleaseAssetMetadata Installer);

    internal static class ReleaseMetadataParser
    {
        internal const string InstallerAssetName = "Pausely-Windows-Setup.exe";
        internal const long MaximumInstallerAssetSize = 512L * 1024 * 1024;
        private const string ReleaseDownloadPathPrefix =
            "/pdevh/Pausely/releases/download/";

        private static readonly Regex SemanticVersionPattern = new(
            @"^(?:v)?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$",
            RegexOptions.CultureInvariant);

        internal static bool TryParseSemanticVersion(
            string? value,
            out Version version,
            out string normalizedVersion)
        {
            version = new Version(0, 0, 0);
            normalizedVersion = "";

            if (string.IsNullOrWhiteSpace(value))
            {
                return false;
            }

            Match match = SemanticVersionPattern.Match(value);
            if (!match.Success ||
                !int.TryParse(match.Groups[1].Value, out int major) ||
                !int.TryParse(match.Groups[2].Value, out int minor) ||
                !int.TryParse(match.Groups[3].Value, out int patch))
            {
                return false;
            }

            version = new Version(major, minor, patch);
            normalizedVersion = $"{major}.{minor}.{patch}";
            return true;
        }

        internal static bool TryParseSha256Digest(
            string? digest,
            out byte[] digestBytes)
        {
            digestBytes = Array.Empty<byte>();
            const string prefix = "sha256:";

            if (string.IsNullOrWhiteSpace(digest) ||
                !digest.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }

            string hex = digest[prefix.Length..];
            if (hex.Length != 64)
            {
                return false;
            }

            try
            {
                digestBytes = Convert.FromHexString(hex);
                return digestBytes.Length == 32;
            }
            catch (FormatException)
            {
                digestBytes = Array.Empty<byte>();
                return false;
            }
        }

        internal static bool TryParseLatestRelease(
            string json,
            out ReleaseMetadata? release,
            out string error)
        {
            release = null;
            error = "";

            try
            {
                using JsonDocument document = JsonDocument.Parse(json);
                JsonElement root = document.RootElement;
                if (root.ValueKind != JsonValueKind.Object ||
                    HasDuplicateProperties(root))
                {
                    error =
                        "Release metadata must be an object without duplicate properties.";
                    return false;
                }

                if (!TryGetRequiredString(root, "tag_name", out string tagName) ||
                    !tagName.StartsWith("v", StringComparison.Ordinal) ||
                    !TryParseSemanticVersion(tagName, out Version version, out string versionText))
                {
                    error = "Release metadata contains no strict vMAJOR.MINOR.PATCH tag.";
                    return false;
                }

                if (!root.TryGetProperty("assets", out JsonElement assets) ||
                    assets.ValueKind != JsonValueKind.Array)
                {
                    error = "Release metadata contains no assets array.";
                    return false;
                }

                ReleaseAssetMetadata? installer = null;
                var seenNames = new HashSet<string>(StringComparer.Ordinal);
                foreach (JsonElement asset in assets.EnumerateArray())
                {
                    if (asset.ValueKind != JsonValueKind.Object ||
                        HasDuplicateProperties(asset) ||
                        !TryGetRequiredString(asset, "name", out string name))
                    {
                        error = "Release metadata contains a malformed asset.";
                        return false;
                    }

                    if (!seenNames.Add(name))
                    {
                        error = $"Release metadata contains duplicate asset '{name}'.";
                        return false;
                    }

                    if (!name.Equals(InstallerAssetName, StringComparison.Ordinal))
                    {
                        continue;
                    }

                    if (!TryGetRequiredString(
                            asset,
                            "browser_download_url",
                            out string downloadUrl) ||
                        !Uri.TryCreate(downloadUrl, UriKind.Absolute, out Uri? downloadUri) ||
                        downloadUri.Scheme != Uri.UriSchemeHttps ||
                        !downloadUri.Host.Equals("github.com", StringComparison.OrdinalIgnoreCase) ||
                        !downloadUri.AbsolutePath.Equals(
                            $"{ReleaseDownloadPathPrefix}{tagName}/{InstallerAssetName}",
                            StringComparison.Ordinal) ||
                        downloadUri.Query.Length != 0 ||
                        downloadUri.Fragment.Length != 0)
                    {
                        error =
                            $"Release asset '{InstallerAssetName}' has no valid HTTPS download URL.";
                        return false;
                    }

                    if (!asset.TryGetProperty("size", out JsonElement sizeElement) ||
                        !sizeElement.TryGetInt64(out long size) ||
                        size <= 0 ||
                        size > MaximumInstallerAssetSize)
                    {
                        error = $"Release asset '{InstallerAssetName}' has an invalid size.";
                        return false;
                    }

                    if (!TryGetRequiredString(asset, "digest", out string digest) ||
                        !TryParseSha256Digest(digest, out _))
                    {
                        error =
                            $"Release asset '{InstallerAssetName}' has no valid SHA-256 digest.";
                        return false;
                    }

                    installer = new ReleaseAssetMetadata(name, downloadUri, size, digest);
                }

                if (installer == null)
                {
                    error = $"Release asset '{InstallerAssetName}' was not found.";
                    return false;
                }

                string releaseNotes = "";
                if (root.TryGetProperty("body", out JsonElement body))
                {
                    if (body.ValueKind is not JsonValueKind.String and not JsonValueKind.Null)
                    {
                        error = "Release notes must be a string or null.";
                        return false;
                    }

                    releaseNotes = body.GetString() ?? "";
                }

                release = new ReleaseMetadata(version, versionText, releaseNotes, installer);
                return true;
            }
            catch (JsonException ex)
            {
                error = $"Release metadata is not valid JSON: {ex.Message}";
                return false;
            }
        }

        private static bool TryGetRequiredString(
            JsonElement element,
            string propertyName,
            out string value)
        {
            value = "";
            if (!element.TryGetProperty(propertyName, out JsonElement property) ||
                property.ValueKind != JsonValueKind.String)
            {
                return false;
            }

            value = property.GetString() ?? "";
            return !string.IsNullOrWhiteSpace(value);
        }

        private static bool HasDuplicateProperties(JsonElement element)
        {
            var names = new HashSet<string>(StringComparer.Ordinal);
            foreach (JsonProperty property in element.EnumerateObject())
            {
                if (!names.Add(property.Name))
                {
                    return true;
                }
            }

            return false;
        }
    }
}
