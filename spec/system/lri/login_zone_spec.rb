# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

# Telas de login por zona (docs/lri/esteira/login-zona/ux-spec-v1.yaml). Grava as screenshots do estágio B em
# tmp/screenshots/lri; o workflow lri-telas.yaml publica a pasta como artefato.
RSpec.describe 'Grupo LRI login screen per zone', authenticated_as: false, type: :system do
  let(:screenshot_dir) { Rails.root.join('tmp/screenshots/lri') }

  before do
    Setting.set('auth_google_oauth2', true)
    Setting.set('auth_microsoft_office365', true)
    enforce_lri_zone_guard
    allow(Lri::Zone).to receive(:resolve).and_return(Lri::Zone.new(zone_name))
    FileUtils.mkdir_p(screenshot_dir)
  end

  # A régua de tela (medir-tela.js) é privada e chega só pelo secret LRI_MEDIR_TELA; sem ele, só a imagem.
  def capture(name)
    page.save_screenshot(screenshot_dir.join("#{name}.png").to_s) # rubocop:disable Lint/Debugger

    probe = ENV['LRI_MEDIR_TELA'].to_s.strip.delete_suffix(';')
    return if probe.blank?

    page.execute_script("window.UI_LR = { raiz: 'body' }; window.__lriMedida = #{probe};")
    screenshot_dir.join("#{name}.json").write(JSON.pretty_generate(page.evaluate_script('window.__lriMedida')))
  end

  shared_examples 'a login screen per zone' do |prefix, width, height|
    before { page.current_window.resize_to(width, height) }

    context 'with the public zone' do
      let(:zone_name) { 'public' }

      it 'shows the password form without any third-party provider', :aggregate_failures do
        open_login
        expect(page).to have_no_button('Google')
        expect(page).to have_no_button('Microsoft')
        expect(page).to have_no_css('.auth-providers, [data-test-id="loginThirdParty"]')
        capture("#{prefix}-publica")
      end
    end

    context 'with the internal zone' do
      let(:zone_name) { 'internal' }

      it 'shows the Google and Microsoft buttons', :aggregate_failures do
        open_login
        expect(page).to have_button('Google')
        expect(page).to have_button('Microsoft')
        capture("#{prefix}-interna")
      end
    end
  end

  describe 'legacy interface' do
    def open_login
      visit 'login'
      expect(page).to have_css('#login')
    end

    it_behaves_like 'a login screen per zone', 'v1-legado-1440', 1440, 900
    it_behaves_like 'a login screen per zone', 'v1-legado-1024', 1024, 768

    context 'with a single provider and the automatic redirect on the public zone' do
      let(:zone_name) { 'public' }

      before do
        Setting.set('auth_microsoft_office365', false)
        Setting.set('third_party_login_auto_redirect', true)
      end

      it 'stays on the login screen' do
        page.current_window.resize_to(1440, 900)
        open_login
        expect(page).to have_field('username')
        expect(page).to have_no_text('Acesso da equipe')
        capture('v5-legado-sem-redirecionamento')
      end
    end
  end

  describe 'desktop interface', app: :desktop_view do
    def open_login
      visit '/login'
      expect(page).to have_button('Sign in')
    end

    it_behaves_like 'a login screen per zone', 'v2-desktop-1440', 1440, 900
    it_behaves_like 'a login screen per zone', 'v2-desktop-1024', 1024, 768
  end

  describe 'mobile interface', app: :mobile do
    def open_login
      visit '/login'
      expect(page).to have_text('Continue to desktop')
    end

    it_behaves_like 'a login screen per zone', 'v3-mobile-390', 390, 844
  end
end
