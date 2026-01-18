const LocalPlayer = {
  currentAudio: null,
  currentButton: null,

  mounted() {
    this.el.addEventListener("click", () => {
      const filename = this.el.dataset.filename;
      
      // If clicking the same button that's currently playing, stop it
      if (LocalPlayer.currentButton === this.el && LocalPlayer.currentAudio) {
        // Stop the audio and reset the button
        LocalPlayer.currentAudio.pause();
        LocalPlayer.currentAudio.currentTime = 0;
        LocalPlayer.currentAudio = null;
        this.updateIcon(false);
        LocalPlayer.currentButton = null;
        return;
      }

      // If a different audio is already playing, block the new request
      if (LocalPlayer.currentAudio && LocalPlayer.currentButton) {
        // Don't play new sound - one is already playing
        return;
      }

      // Play the new audio
      LocalPlayer.currentAudio = new Audio(`/uploads/${filename}`);
      LocalPlayer.currentButton = this.el;
      LocalPlayer.currentAudio.play();
      this.updateIcon(true);

      // When audio ends, reset the button
      LocalPlayer.currentAudio.onended = () => {
        this.updateIcon(false);
        LocalPlayer.currentAudio = null;
        LocalPlayer.currentButton = null;
      };
    });
  },

  updateIcon(isPlaying) {
    this.el.querySelector('svg').outerHTML = isPlaying ? this.stopIcon() : this.playIcon();
  },

  playIcon() {
    return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 640" fill="currentColor" class="w-4 h-4">
      <path d="M144 288C144 190.8 222.8 112 320 112C417.2 112 496 190.8 496 288L496 332.8C481.9 324.6 465.5 320 448 320L432 320C405.5 320 384 341.5 384 368L384 496C384 522.5 405.5 544 432 544L448 544C501 544 544 501 544 448L544 288C544 164.3 443.7 64 320 64C196.3 64 96 164.3 96 288L96 448C96 501 139 544 192 544L208 544C234.5 544 256 522.5 256 496L256 368C256 341.5 234.5 320 208 320L192 320C174.5 320 158.1 324.7 144 332.8L144 288zM144 416C144 389.5 165.5 368 192 368L208 368L208 496L192 496C165.5 496 144 474.5 144 448L144 416zM496 416L496 448C496 474.5 474.5 496 448 496L432 496L432 368L448 368C474.5 368 496 389.5 496 416z"/>
    </svg>`;
  },

  stopIcon() {
    return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="w-4 h-4">
      <path fill-rule="evenodd" d="M4.5 7.5a3 3 0 013-3h9a3 3 0 013 3v9a3 3 0 01-3 3h-9a3 3 0 01-3-3v-9z" clip-rule="evenodd" />
    </svg>`;
  }
}

export default LocalPlayer; 