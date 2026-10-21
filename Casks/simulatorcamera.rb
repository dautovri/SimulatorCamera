cask "simulatorcamera" do
  version "1.1.0"
  sha256 "1c147504d744d4a27bdeb2f2bcbc04768436a852ff54c3c5f43d44e8b5b51e11"

  url "https://github.com/dautovri/SimulatorCamera/releases/download/v#{version}/SimulatorCamera-#{version}.dmg",
      verified: "github.com/dautovri/SimulatorCamera/"
  name "SimulatorCamera"
  desc "Open-source virtual camera for the iOS Simulator (Camera Extension)"
  homepage "https://github.com/dautovri/SimulatorCamera"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "SimulatorCamera.app"

  uninstall delete: [
    "/Applications/SimulatorCamera.app",
  ]

  zap trash: [
    "~/Library/Preferences/com.dautov.SimulatorCamera.plist",
    "~/Library/Application Support/SimulatorCamera",
    "~/Library/Containers/com.dautov.SimulatorCamera",
    "~/Library/Containers/com.dautov.SimulatorCamera.Extension",
  ]
end
