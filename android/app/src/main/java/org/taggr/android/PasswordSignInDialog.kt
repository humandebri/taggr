package org.taggr.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties

@Composable
internal fun PasswordSignInDialog(
    busy: Boolean,
    error: String?,
    dismiss: () -> Unit,
    signIn: (String) -> Unit,
) {
    // Deliberately not saveable: neither the password nor its derived root belongs in saved state.
    var phrase by remember { mutableStateOf("") }
    DisposableEffect(Unit) { onDispose { phrase = "" } }
    val close = {
        phrase = ""
        dismiss()
    }
    Dialog(
        onDismissRequest = { if (!busy) close() },
        properties =
            DialogProperties(
                dismissOnBackPress = !busy,
                dismissOnClickOutside = !busy,
                securePolicy = androidx.compose.ui.window.SecureFlagPolicy.SecureOn,
            ),
    ) {
        Surface(shape = MaterialTheme.shapes.large) {
            Column(
                Modifier.padding(20.dp).verticalScroll(rememberScrollState()).imePadding(),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Text("Password", style = MaterialTheme.typography.titleLarge)
                Text(
                    "Enter the same password you use on TAGGR's website. Spaces and capitalization must match. Internet Identity accounts use their original sign-in method."
                )
                OutlinedTextField(
                    value = phrase,
                    onValueChange = { phrase = it },
                    label = { Text("Password") },
                    modifier = Modifier.fillMaxWidth().testTag("password-input"),
                    enabled = !busy,
                    singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions =
                        KeyboardOptions(
                            autoCorrectEnabled = false,
                            keyboardType = KeyboardType.Password,
                        ),
                )
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    TextButton(onClick = close, enabled = !busy) { Text("Cancel") }
                    Button(
                        onClick = {
                            val entered = phrase
                            phrase = ""
                            signIn(entered)
                        },
                        enabled = !busy && phrase.isNotEmpty(),
                    ) {
                        Text(if (busy) "Signing in..." else "Sign in")
                    }
                }
            }
        }
    }
}
