package com.arqUTB.savioappapi

object UserSession {
    var displayName: String? = null
    var givenName: String? = null
    var surname: String? = null
    var mail: String? = null
    var upn: String? = null
    var accessToken: String? = null
    var refreshToken: String? = null
    fun clear() {
        displayName = null
        givenName = null
        surname = null
        mail = null
        upn = null
        accessToken = null
        refreshToken = null
    }
}
