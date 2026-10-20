import { mount } from '@vue/test-utils';
import ReplyBottomPanel from '../ReplyBottomPanel.vue';

// Barra de resposta estilo WhatsApp: os mesmos recursos de antes, reorganizados
// em [+][emoji][cadeado] [campo] [microfone/enviar].
const setSignatureFlagForInbox = vi.fn();
vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    setSignatureFlagForInbox: (...args) => setSignatureFlagForInbox(...args),
    fetchSignatureFlagFromUISettings: () => false,
  }),
}));
vi.mock('dashboard/composables/useKeyboardEvents', () => ({
  useKeyboardEvents: () => {},
}));
vi.mock('activestorage', () => ({ start: () => {} }));

const montar = (props = {}) =>
  mount(ReplyBottomPanel, {
    props: {
      conversationId: 7,
      portalSlug: '',
      inbox: { id: 1, channel_type: 'Channel::Whatsapp' },
      showFileUpload: true,
      showAudioRecorder: true,
      isSendDisabled: true,
      message: '',
      sendButtonText: 'Enviar (↵)',
      ...props,
    },
    global: {
      mocks: {
        $t: chave => chave,
        $store: {
          getters: {
            getCurrentAccountId: 1,
            'accounts/isFeatureEnabledonAccount': () => true,
            'integrations/getUIFlags': { isFetching: false },
          },
        },
      },
      stubs: {
        FileUpload: true,
        VideoCallButton: true,
        NextButton: true,
        'fluent-icon': true,
      },
    },
  });

const byTest = (wrapper, id) => wrapper.find(`[data-test-id="${id}"]`);

describe('ReplyBottomPanel (barra estilo WhatsApp)', () => {
  it('mostra o microfone quando não há texto e grava com a função de sempre', async () => {
    const toggleAudioRecorder = vi.fn();
    const wrapper = montar({ toggleAudioRecorder });

    expect(byTest(wrapper, 'trama-barra-enviar').exists()).toBe(false);
    await byTest(wrapper, 'trama-barra-microfone').trigger('click');
    expect(toggleAudioRecorder).toHaveBeenCalledTimes(1);
  });

  it('troca o microfone pelo enviar quando há texto', async () => {
    const onSend = vi.fn();
    const wrapper = montar({
      message: 'Olá, tudo bem?',
      isSendDisabled: false,
      onSend,
    });

    expect(byTest(wrapper, 'trama-barra-microfone').exists()).toBe(false);
    const enviar = byTest(wrapper, 'trama-barra-enviar');
    expect(enviar.attributes('aria-label')).toBe('Enviar (↵)');
    await enviar.trigger('click');
    expect(onSend).toHaveBeenCalledTimes(1);
  });

  it('mantém o enviar (desabilitado) quando o canal não grava áudio', () => {
    const wrapper = montar({ showAudioRecorder: false });

    expect(byTest(wrapper, 'trama-barra-microfone').exists()).toBe(false);
    expect(
      byTest(wrapper, 'trama-barra-enviar').attributes('disabled')
    ).toBeDefined();
  });

  it('o "+" reúne anexos e o modelo do WhatsApp', async () => {
    const wrapper = montar({ enableWhatsAppTemplates: true });

    expect(wrapper.find('[role="menu"]').exists()).toBe(false);
    await byTest(wrapper, 'trama-barra-mais').trigger('click');

    expect(byTest(wrapper, 'trama-barra-fotos').exists()).toBe(true);
    expect(byTest(wrapper, 'trama-barra-documento').exists()).toBe(true);
    expect(byTest(wrapper, 'trama-barra-gravar').exists()).toBe(true);

    await byTest(wrapper, 'trama-barra-modelo').trigger('click');
    expect(wrapper.emitted('selectWhatsappTemplate')).toHaveLength(1);
    expect(wrapper.find('[role="menu"]').exists()).toBe(false);
  });

  it('assinatura, IA e expandir continuam acessíveis pelo "+"', async () => {
    const wrapper = montar({ showCopilotAction: true, showPopoutAction: true });
    await byTest(wrapper, 'trama-barra-mais').trigger('click');

    await byTest(wrapper, 'trama-barra-assinatura').trigger('click');
    expect(setSignatureFlagForInbox).toHaveBeenCalledWith(
      'Channel::Whatsapp',
      true
    );

    await byTest(wrapper, 'trama-barra-mais').trigger('click');
    await byTest(wrapper, 'trama-barra-ia').trigger('click');
    expect(wrapper.emitted('openCopilot')).toHaveLength(1);

    await byTest(wrapper, 'trama-barra-mais').trigger('click');
    await byTest(wrapper, 'trama-barra-expandir').trigger('click');
    expect(wrapper.emitted('togglePopout')).toHaveLength(1);
  });

  it('"Fotos e vídeos" abre o mesmo seletor de arquivos, filtrado para mídia', async () => {
    const input = document.createElement('input');
    input.id = 'conversationAttachment';
    document.body.appendChild(input);
    const clique = vi.spyOn(input, 'click');

    const wrapper = montar();
    await byTest(wrapper, 'trama-barra-mais').trigger('click');
    await byTest(wrapper, 'trama-barra-fotos').trigger('click');
    await wrapper.vm.$nextTick();

    expect(clique).toHaveBeenCalledTimes(1);
    expect(wrapper.vm.mediaFileTypes).toMatch(/image\//);
    expect(wrapper.vm.mediaFileTypes).not.toMatch(/application\//);
    input.remove();
  });

  it('o cadeado alterna para nota privada e some quando já está na nota', async () => {
    const wrapper = montar();
    await byTest(wrapper, 'trama-barra-nota').trigger('click');
    expect(wrapper.emitted('togglePrivateNote')).toHaveLength(1);

    await wrapper.setProps({ isNote: true });
    expect(byTest(wrapper, 'trama-barra-nota').exists()).toBe(false);
  });

  it('janela de 24 h fechada: emoji desabilitado, mas o modelo do WhatsApp segue no "+"', async () => {
    const wrapper = montar({
      isEditorDisabled: true,
      enableWhatsAppTemplates: true,
    });

    expect(
      byTest(wrapper, 'trama-barra-emoji').attributes('disabled')
    ).toBeDefined();
    await byTest(wrapper, 'trama-barra-mais').trigger('click');
    expect(byTest(wrapper, 'trama-barra-fotos').exists()).toBe(false);
    expect(byTest(wrapper, 'trama-barra-modelo').exists()).toBe(true);
  });
});
