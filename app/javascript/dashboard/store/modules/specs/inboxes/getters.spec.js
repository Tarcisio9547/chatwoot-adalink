import { getters } from '../../inboxes';
import inboxList from './fixtures';
import { templates } from './templateFixtures';

describe('#getters', () => {
  it('getInboxes', () => {
    const state = {
      records: inboxList,
    };
    expect(getters.getInboxes(state)).toEqual(inboxList);
  });

  it('getWebsiteInboxes', () => {
    const state = { records: inboxList };
    expect(getters.getWebsiteInboxes(state).length).toEqual(3);
  });

  it('getTwilioInboxes', () => {
    const state = { records: inboxList };
    expect(getters.getTwilioInboxes(state).length).toEqual(1);
  });

  it('getSMSInboxes', () => {
    const state = { records: inboxList };
    expect(getters.getSMSInboxes(state).length).toEqual(2);
  });

  it('dialogFlowEnabledInboxes', () => {
    const state = { records: inboxList };
    expect(getters.dialogFlowEnabledInboxes(state).length).toEqual(8);
  });

  it('getInbox', () => {
    const state = {
      records: inboxList,
    };
    expect(getters.getInbox(state)(1)).toEqual({
      id: 1,
      channel_id: 1,
      name: 'Test FacebookPage 1',
      channel_type: 'Channel::FacebookPage',
      avatar_url: 'random_image.png',
      page_id: '12345',
      widget_color: null,
      website_token: null,
      enable_auto_assignment: true,
      instagram_id: 123456789,
    });
  });

  it('getUIFlags', () => {
    const state = {
      uiFlags: {
        isFetching: true,
        isFetchingItem: false,
        isCreating: false,
        isUpdating: false,
        isDeleting: false,
      },
    };
    expect(getters.getUIFlags(state)).toEqual({
      isFetching: true,
      isFetchingItem: false,
      isCreating: false,
      isUpdating: false,
      isDeleting: false,
    });
  });

  it('getFacebookInboxByInstagramId', () => {
    const state = { records: inboxList };
    expect(getters.getFacebookInboxByInstagramId(state)(123456789)).toEqual({
      id: 1,
      channel_id: 1,
      name: 'Test FacebookPage 1',
      channel_type: 'Channel::FacebookPage',
      avatar_url: 'random_image.png',
      page_id: '12345',
      widget_color: null,
      website_token: null,
      enable_auto_assignment: true,
      instagram_id: 123456789,
    });
  });

  it('getInstagramInboxByInstagramId', () => {
    const state = { records: inboxList };
    expect(getters.getInstagramInboxByInstagramId(state)(123456789)).toEqual({
      id: 7,
      channel_id: 7,
      name: 'Test Instagram 1',
      channel_type: 'Channel::Instagram',
      instagram_id: 123456789,
      provider: 'default',
    });
  });

  it('getTiktokInboxByBusinessId', () => {
    const state = { records: inboxList };
    expect(getters.getTiktokInboxByBusinessId(state)(123456789)).toEqual({
      id: 8,
      channel_id: 8,
      name: 'Test TikTok 1',
      channel_type: 'Channel::Tiktok',
      business_id: 123456789,
      provider: 'default',
    });
  });

  describe('getFilteredWhatsAppTemplates', () => {
    it('returns empty array when inbox not found', () => {
      const state = { records: [] };
      expect(getters.getFilteredWhatsAppTemplates(state)(999)).toEqual([]);
    });

    it('returns empty array when templates is null or undefined', () => {
      const state = {
        records: [
          {
            id: 1,
            channel_type: 'Channel::Whatsapp',
            message_templates: null,
            additional_attributes: { message_templates: undefined },
          },
        ],
      };
      expect(getters.getFilteredWhatsAppTemplates(state)(1)).toEqual([]);
    });

    it('returns empty array when templates is not an array', () => {
      const state = {
        records: [
          {
            id: 1,
            channel_type: 'Channel::Whatsapp',
            message_templates: 'invalid',
            additional_attributes: {},
          },
        ],
      };
      expect(getters.getFilteredWhatsAppTemplates(state)(1)).toEqual([]);
    });

    it('filters out templates without required properties', () => {
      const invalidTemplates = [
        { name: 'incomplete_template' }, // missing status and components
        { status: 'approved' }, // missing name and components
        { name: 'another_incomplete', status: 'approved' }, // missing components
      ];

      const state = {
        records: [
          {
            id: 1,
            channel_type: 'Channel::Whatsapp',
            message_templates: invalidTemplates,
          },
        ],
      };
      expect(getters.getFilteredWhatsAppTemplates(state)(1)).toEqual([]);
    });

    it('filters out non-approved templates', () => {
      const mixedStatusTemplates = [
        {
          name: 'pending_template',
          status: 'pending',
          components: [{ type: 'BODY', text: 'Test' }],
        },
        {
          name: 'rejected_template',
          status: 'rejected',
          components: [{ type: 'BODY', text: 'Test' }],
        },
        {
          name: 'approved_template',
          status: 'approved',
          components: [{ type: 'BODY', text: 'Test' }],
        },
      ];

      const state = {
        records: [
          {
            id: 1,
            channel_type: 'Channel::Whatsapp',
            message_templates: mixedStatusTemplates,
          },
        ],
      };

      const result = getters.getFilteredWhatsAppTemplates(state)(1);
      expect(result).toHaveLength(1);
      expect(result[0].name).toBe('approved_template');
    });

    it('filters out interactive templates (LIST, PRODUCT, CATALOG)', () => {
      const interactiveTemplates = [
        {
          name: 'list_template',
          status: 'approved',
          components: [
            { type: 'BODY', text: 'Choose an option' },
            { type: 'LIST', sections: [] },
          ],
        },
        {
          name: 'product_template',
          status: 'approved',
          components: [
            { type: 'BODY', text: 'Product info' },
            { type: 'PRODUCT', catalog_id: '123' },
          ],
        },
        {
          name: 'catalog_template',
          status: 'approved',
          components: [
            { type: 'BODY', text: 'Catalog' },
            { type: 'CATALOG', thumbnail_product_retailer_id: '123' },
          ],
        },
        {
          name: 'regular_template',
          status: 'approved',
          components: [{ type: 'BODY', text: 'Regular message' }],
        },
      ];

      const state = {
        records: [
          {
            id: 1,
            channel_type: 'Channel::Whatsapp',
            message_templates: interactiveTemplates,
          },
        ],
      };

      const result = getters.getFilteredWhatsAppTemplates(state)(1);
      expect(result).toHaveLength(1);
      expect(result[0].name).toBe('regular_template');
    });

    it('filters out location templates', () => {
      const locationTemplates = [
        {
          name: 'location_template',
          status: 'approved',
          components: [
            { type: 'HEADER', format: 'LOCATION' },
            { type: 'BODY', text: 'Location message' },
          ],
        },
        {
          name: 'regular_template',
          status: 'approved',
          components: [
            { type: 'HEADER', format: 'TEXT', text: 'Header' },
            { type: 'BODY', text: 'Regular message' },
          ],
        },
      ];

      const state = {
        records: [
          {
            id: 1,
            channel_type: 'Channel::Whatsapp',
            message_templates: locationTemplates,
          },
        ],
      };

      const result = getters.getFilteredWhatsAppTemplates(state)(1);
      expect(result).toHaveLength(1);
      expect(result[0].name).toBe('regular_template');
    });

    it('filters out authentication templates', () => {
      const authenticationTemplates = [
        {
          name: 'auth_template',
          status: 'approved',
          category: 'AUTHENTICATION',
          components: [
            { type: 'BODY', text: 'Your verification code is {{1}}' },
          ],
        },
        {
          name: 'regular_template',
          status: 'approved',
          category: 'MARKETING',
          components: [{ type: 'BODY', text: 'Regular message' }],
        },
      ];

      const state = {
        records: [
          {
            id: 1,
            channel_type: 'Channel::Whatsapp',
            message_templates: authenticationTemplates,
          },
        ],
      };

      const result = getters.getFilteredWhatsAppTemplates(state)(1);
      expect(result).toHaveLength(1);
      expect(result[0].name).toBe('regular_template');
    });

    it('returns valid templates from fixture data', () => {
      const state = {
        records: [
          {
            id: 1,
            channel_type: 'Channel::Whatsapp',
            message_templates: templates,
          },
        ],
      };

      const result = getters.getFilteredWhatsAppTemplates(state)(1);

      // All templates in fixtures should be approved and valid
      expect(result.length).toBeGreaterThan(0);

      // Verify all returned templates are approved
      result.forEach(template => {
        expect(template.status).toBe('approved');
        expect(template.components).toBeDefined();
        expect(Array.isArray(template.components)).toBe(true);
      });

      // Verify specific templates from fixtures are included
      const templateNames = result.map(t => t.name);
      expect(templateNames).toContain('sample_flight_confirmation');
      expect(templateNames).toContain('sample_issue_resolution');
      expect(templateNames).toContain('sample_shipping_confirmation');
      expect(templateNames).toContain('no_variable_template');
      expect(templateNames).toContain('order_confirmation');
    });

    describe('lista de permitidos (só o que o Atendimento sabe enviar)', () => {
      const buildState = messageTemplates => ({
        records: [
          {
            id: 1,
            channel_type: 'Channel::Whatsapp',
            message_templates: messageTemplates,
          },
        ],
      });

      const approved = (name, components) => ({
        name,
        status: 'approved',
        category: 'MARKETING',
        language: 'pt_BR',
        components,
      });

      const filterNames = messageTemplates =>
        getters
          .getFilteredWhatsAppTemplates(buildState(messageTemplates))(1)
          .map(template => template.name);

      it('esconde o modelo carrossel (a Meta devolve #132012 se enviado incompleto)', () => {
        const carousel = approved('promo_carrossel', [
          { type: 'BODY', text: 'Confira os imóveis' },
          {
            type: 'CAROUSEL',
            cards: [
              {
                components: [
                  { type: 'HEADER', format: 'IMAGE' },
                  { type: 'BODY', text: 'Cobertura {{1}}' },
                  {
                    type: 'BUTTONS',
                    buttons: [{ type: 'URL', text: 'Ver', url: 'https://x.com' }],
                  },
                ],
              },
            ],
          },
        ]);
        const regular = approved('simples', [{ type: 'BODY', text: 'Olá' }]);

        expect(filterNames([carousel, regular])).toEqual(['simples']);
      });

      it('esconde o modelo de oferta por tempo limitado (LTO)', () => {
        const lto = approved('oferta_relampago', [
          { type: 'HEADER', format: 'IMAGE' },
          { type: 'LIMITED_TIME_OFFER', limited_time_offer: { text: 'Hoje' } },
          { type: 'BODY', text: 'Só hoje' },
          {
            type: 'BUTTONS',
            buttons: [{ type: 'COPY_CODE', example: 'CODIGO10' }],
          },
        ]);
        const regular = approved('simples', [{ type: 'BODY', text: 'Olá' }]);

        expect(filterNames([lto, regular])).toEqual(['simples']);
      });

      it('esconde o modelo com botão de FLOW', () => {
        const flow = approved('formulario_flow', [
          { type: 'BODY', text: 'Preencha o formulário' },
          {
            type: 'BUTTONS',
            buttons: [{ type: 'FLOW', text: 'Abrir', flow_id: '123' }],
          },
        ]);
        const regular = approved('simples', [{ type: 'BODY', text: 'Olá' }]);

        expect(filterNames([flow, regular])).toEqual(['simples']);
      });

      it('esconde o modelo com botão misturado quando um deles não é suportado', () => {
        const mixed = approved('misto', [
          { type: 'BODY', text: 'Escolha' },
          {
            type: 'BUTTONS',
            buttons: [
              { type: 'QUICK_REPLY', text: 'Sim' },
              { type: 'FLOW', text: 'Abrir', flow_id: '123' },
            ],
          },
        ]);

        expect(filterNames([mixed])).toEqual([]);
      });

      it('esconde tipos de componente que ainda não existem (desconhecido)', () => {
        const unknown = approved('futuro', [
          { type: 'BODY', text: 'Novo' },
          { type: 'TIPO_NOVO_DA_META', foo: 'bar' },
        ]);
        const regular = approved('simples', [{ type: 'BODY', text: 'Olá' }]);

        expect(filterNames([unknown, regular])).toEqual(['simples']);
      });

      it('esconde formato de cabeçalho desconhecido ou sem formato', () => {
        const unknownFormat = approved('cabecalho_novo', [
          { type: 'HEADER', format: 'FORMATO_NOVO' },
          { type: 'BODY', text: 'Olá' },
        ]);
        const noFormat = approved('cabecalho_sem_formato', [
          { type: 'HEADER' },
          { type: 'BODY', text: 'Olá' },
        ]);
        const location = approved('cabecalho_local', [
          { type: 'HEADER', format: 'LOCATION' },
          { type: 'BODY', text: 'Olá' },
        ]);

        expect(filterNames([unknownFormat, noFormat, location])).toEqual([]);
      });

      it('esconde tipo de botão desconhecido', () => {
        const unknownButton = approved('botao_novo', [
          { type: 'BODY', text: 'Olá' },
          {
            type: 'BUTTONS',
            buttons: [{ type: 'BOTAO_NOVO', text: 'Clique' }],
          },
        ]);

        expect(filterNames([unknownButton])).toEqual([]);
      });

      it('esconde modelo cujos componentes não vêm como lista', () => {
        const broken = { ...approved('quebrado', []), components: 'texto' };

        expect(filterNames([broken])).toEqual([]);
      });

      it.each(['TEXT', 'IMAGE', 'VIDEO', 'DOCUMENT'])(
        'mantém cabeçalho com formato %s',
        format => {
          const withHeader = approved('com_cabecalho', [
            { type: 'HEADER', format },
            { type: 'BODY', text: 'Olá' },
            { type: 'FOOTER', text: 'Rodapé' },
          ]);

          expect(filterNames([withHeader])).toEqual(['com_cabecalho']);
        }
      );

      it.each(['QUICK_REPLY', 'URL', 'PHONE_NUMBER', 'COPY_CODE'])(
        'mantém botão do tipo %s',
        type => {
          const withButton = approved('com_botao', [
            { type: 'BODY', text: 'Olá' },
            { type: 'BUTTONS', buttons: [{ type, text: 'Botão' }] },
          ]);

          expect(filterNames([withButton])).toEqual(['com_botao']);
        }
      );

      it('mantém modelo com os quatro tipos de botão juntos', () => {
        const allButtons = approved('todos_botoes', [
          { type: 'HEADER', format: 'TEXT', text: 'Título' },
          { type: 'BODY', text: 'Olá' },
          { type: 'FOOTER', text: 'Rodapé' },
          {
            type: 'BUTTONS',
            buttons: [
              { type: 'QUICK_REPLY', text: 'Sim' },
              { type: 'URL', text: 'Site', url: 'https://x.com/{{1}}' },
              { type: 'PHONE_NUMBER', text: 'Ligar', phone_number: '+5511' },
              { type: 'COPY_CODE', text: 'Copiar' },
            ],
          },
        ]);

        expect(filterNames([allButtons])).toEqual(['todos_botoes']);
      });

      it('mantém todos os modelos válidos que já existem nos fixtures', () => {
        const result = getters.getFilteredWhatsAppTemplates(
          buildState(templates)
        )(1);

        expect(result).toHaveLength(templates.length);
      });

      it('mantém as exclusões antigas: não aprovado, AUTHENTICATION e CSAT', () => {
        const pending = {
          ...approved('pendente', [{ type: 'BODY', text: 'Olá' }]),
          status: 'pending',
        };
        const auth = {
          ...approved('codigo', [{ type: 'BODY', text: 'Código {{1}}' }]),
          category: 'AUTHENTICATION',
        };
        const csat = approved('customer_satisfaction_survey_12', [
          { type: 'BODY', text: 'Nota?' },
        ]);
        const regular = approved('simples', [{ type: 'BODY', text: 'Olá' }]);

        expect(filterNames([pending, auth, csat, regular])).toEqual(['simples']);
      });
    });

    it('prioritizes message_templates over additional_attributes.message_templates', () => {
      const primaryTemplates = [
        {
          name: 'primary_template',
          status: 'approved',
          components: [{ type: 'BODY', text: 'Primary' }],
        },
      ];

      const fallbackTemplates = [
        {
          name: 'fallback_template',
          status: 'approved',
          components: [{ type: 'BODY', text: 'Fallback' }],
        },
      ];

      const state = {
        records: [
          {
            id: 1,
            channel_type: 'Channel::Whatsapp',
            message_templates: primaryTemplates,
            additional_attributes: {
              message_templates: fallbackTemplates,
            },
          },
        ],
      };

      const result = getters.getFilteredWhatsAppTemplates(state)(1);
      expect(result).toHaveLength(1);
      expect(result[0].name).toBe('primary_template');
    });

    it('falls back to additional_attributes.message_templates when message_templates is null', () => {
      const fallbackTemplates = [
        {
          name: 'fallback_template',
          status: 'approved',
          components: [{ type: 'BODY', text: 'Fallback' }],
        },
      ];

      const state = {
        records: [
          {
            id: 1,
            channel_type: 'Channel::Whatsapp',
            message_templates: null,
            additional_attributes: {
              message_templates: fallbackTemplates,
            },
          },
        ],
      };

      const result = getters.getFilteredWhatsAppTemplates(state)(1);
      expect(result).toHaveLength(1);
      expect(result[0].name).toBe('fallback_template');
    });
  });
});
