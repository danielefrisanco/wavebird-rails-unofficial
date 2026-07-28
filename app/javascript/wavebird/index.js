import WavebirdController from "controllers/wavebird_controller";

// Registers the wavebird Stimulus controller under the identifier `wavebird`,
// matching the `data-controller="wavebird"` the `wavebird_slot` view helper
// emits. Call this once from the host app's Stimulus entrypoint:
//
//   import { Application } from "@hotwired/stimulus";
//   import { registerWavebirdControllers } from "wavebird";
//   const application = Application.start();
//   registerWavebirdControllers(application);
//
// See INSTALL.md for importmap and jsbundling setups.
export function registerWavebirdControllers(application) {
  application.register("wavebird", WavebirdController);
}

export { WavebirdController };
