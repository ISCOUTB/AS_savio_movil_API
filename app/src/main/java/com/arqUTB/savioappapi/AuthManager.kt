package com.arqUTB.savioappapi

object AuthManager {
    fun signOut(onDone: (() -> Unit)? = null) { onDone?.invoke() }
}
