# ── The AI sidebar: two extra models, and streams that cannot hang.
#
# Gemini 3.6 Flash. Upstream's built-in Gemini entries stop at
# gemini-3-flash-preview. This one goes first in the models object, so it is
# also modelList[0] — the fallback when Persistent holds no model or one
# that no longer exists. Same key_id as the other Gemini entries, so one key
# in the keyring serves all three. Checked against the API with a real key:
# models/gemini-3.6-flash exists and answers streamGenerateContent, which is
# the endpoint GeminiApiStrategy calls.
#
# DeepSeek V4 Flash through gonka24, second. An OpenAI-compatible endpoint,
# so upstream's OpenAiApiStrategy drives it unchanged, with its key under
# key_id "gonka24". One thing it needs: extraParams sends `tools: []`, i.e.
# no sidebar functions for this model. OpenAiApiStrategy ignores tool_calls
# entirely, and this model reaches for the tools readily — asked a plain
# question it streamed a run_shell_command call, which the sidebar would
# have shown as an empty reply. tool_choice "none" is no fix here: the model
# still generates the call and the provider drops it, again an empty reply
# (3 of 3 runs). `tools: null` is rejected ("Expected array"); `[]` answers
# normally. All tested against the endpoint with a real key.
#
# Patched into Ai.qml rather than added through config.json's ai.extraModels:
# config.json is written by the shell at runtime and holds nothing this repo
# seeds, the same reason the capture paths are QML defaults.
{ pkgs, qsConfig, fill, ... }: let
  geminiModel = "gemini-3.6-flash";
  gonkaModel = "deepseek-v4-flash-0731";
  aiModelEntries = pkgs.writeText "ii-ai-extra-models" (fill ./files/ai-models.qml {
    inherit geminiModel gonkaModel;
  });
in {
  patch = ''
    # Gemini is also the default for a fresh states.json. The entries are
    # written unindented; put Ai.qml's indentation back.
    sed 's/^./        &/' ${aiModelEntries} > $TMPDIR/ai-model-entries
    for s in ii ${qsConfig}; do
      sed -i '/^    property var models: Config.options.policies.ai === 2 ? {} : {$/r '"$TMPDIR"'/ai-model-entries' \
        $out/.config/quickshell/$s/services/Ai.qml
      grep -q '"model": "${geminiModel}",' $out/.config/quickshell/$s/services/Ai.qml
      grep -q '"model": "${gonkaModel}",' $out/.config/quickshell/$s/services/Ai.qml
      substituteInPlace $out/.config/quickshell/$s/modules/common/Persistent.qml \
        --replace-fail 'property string model: "gemini-2.5-flash"' 'property string model: "${geminiModel}"'

      # A stalled stream must end. Upstream's curl has no timeout at all, and
      # Gemini under load sometimes stops sending mid-answer while keeping the
      # connection open: seen here as a request.sh curl still ESTABLISHED four
      # minutes in with nothing arriving, the message never marked done, the
      # reply frozen mid-sentence. 90s of silence rather than a total cap, so a
      # long answer is never cut, and generous because a thinking model can be
      # quiet for a while before its first chunk. Exit 28 is curl's timeout;
      # it gets a visible note instead of just ending mid-sentence.
      substituteInPlace $out/.config/quickshell/$s/services/Ai.qml \
        --replace-fail 'scriptRequestContent += `curl --no-buffer "''${endpoint}"`' \
                       'scriptRequestContent += `curl --no-buffer --connect-timeout 15 --speed-limit 1 --speed-time 90 "''${endpoint}"`' \
        --replace-fail 'const result = requester.currentStrategy.onRequestFinished(requester.message);' \
                       'const result = requester.currentStrategy.onRequestFinished(requester.message);
                if (exitCode === 28) {
                    const stallNote = "\n\n*(Stream stalled, no data for 90s. Press regenerate to retry.)*";
                    requester.message.rawContent += stallNote;
                    requester.message.content += stallNote;
                }'
    done
  '';
}
